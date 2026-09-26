# 2026-09-02 sync log: late ACKs, BUSY-abort blind spot, duplicate sessions

## Session header

- Date: 2026-09-02, raid night. The pasted window is 22:44:49 to 22:55:55; the audit-store sessions extracted below run from 2026-09-01 20:19 to 2026-09-03 00:45.
- Addon version: 0.38.1 as advertised. The local client was the `feat/sort-include-bags` checkout with no stamp commit and `DEV_BUILD` nil, so it advertised the base version while carrying the #139 bags code (shipped later as v0.39.0). Every peer advertised v0.38.1 except Eltherin-Area52 (v0.38.0).
- Local client: Rexxybear-Tichondrius, sender side throughout. 15064 to 15081 tx and 335 buckets in the pasted window; 14842 tx on 2026-09-01 20:32, 15123 by 2026-09-03 00:34.
- Session: 11 minutes pasted from the `/gbl logs` master pop-up, holding three sends and no receives.
- Peers seen in the pasted window:
  - Kátorri-Stormrage (v0.38.1, 13623 tx): two sends. 56/336 chunks, aborted when the character went offline; 263/436 chunks, aborted by their combat BUSY.
  - Katorrí-Stormrage (v0.38.1, 13623 tx): one HELLO at 22:46:57, 39 seconds after Kátorri went offline, advertising the same count. Same account.
  - Soulcialist (v0.38.1, 13068 tx): one send, 82/346 chunks, aborted after the full ACK ladder on chunk 82.
  - Voxle (v0.38.1, 12929 to 12930 tx): nudged to pull at 22:51:28, requested in the same second, declined.
  - Strikä-Stormrage (v0.38.1, 4949 tx on the evening's HELLOs): two requests arrived truncated at 452 B, the third arrived whole and was declined.

## Provenance, and what is missing

The paste is the only record of its window. The account's `GuildBankLedgerAuditDB` session for this login started at the 22:44:49 reload, and its 1000-entry sync ring had evicted everything before 00:19:58 by the time it was read (`dropped.sync = 5115`), so the store and the paste cover two disjoint slices of one login and 22:56 to 00:19 is lost. The store's five sessions from 2026-09-01 20:19 to this login are extracted below: they carry the same peers earlier in the day and the 00:19 to 00:45 tail of this one. All ten sessions in the store had rotated out by 2026-09-20, when this record was written, so the extracts here are the only copy of those as well. A pasted window is the only durable copy of itself once ten more logins pass.

## Diagnosis summary

1. **The Soulcialist abort was late ACKs, not lost fragments, and the stale-ACK discards are what say so.** Chunks 1 to 75 ran at 0.4 to 0.5 s wire-to-ACK. From chunk 76 the receiver answered late: 18 `Discarded stale ACK` lines between 22:47:34 and 22:49:51, each an ACK for a retransmit the sender had already given up on, six of them for chunk 81 alone. Chunk 81 went out eleven times between 22:48:46 and 22:49:17 and its ACKs arrived from 22:49:22 to 22:49:51, 5 to 34 seconds after the last retransmit; chunk 82 then burned its own eleven attempts and the send aborted at 22:49:52 with `82/346 chunks, 319 records, 187s`. The summary lines cannot see this: `Retry causes for Soulcialist: ackTimeout=32, nack=0, chunkFail=28.1%, p_frag=16.2%` reads as wire loss, and `Wire-to-ACK 0.27s / 0.52s / 2.13s` averages only the ACKs that arrived inside the timeout. The chunk 40 ACK arriving twice at 22:47:29 (1.44 s, once per transmit) is the same receiver already lagging at chunk 40. This is the 2026-08-25 late-ACK finding again (Voxle and Flamè, both raiding, aborting at fragments~=1 with ACKs just past 3 s), on a same-realm peer this time, so route realm is not the variable. The discriminator is the stale-ACK count: the Kátorri send that followed took 19 ACK-timeout retries and produced zero stale ACKs, which is genuine loss, and the two look identical on every summary line. `HandleAck` logs the discard (`Discarded stale ACK for chunk N (expected M)`) and nothing counts it.

2. **A send killed by the peer's BUSY writes no summary block, so the `busy` abort count can only ever read 0.** The 22:55:27 abort of the 263/436 Kátorri send (`Received BUSY from Kátorri-Stormrage (reason: combat)` then `Kátorri-Stormrage busy - aborting send`) is followed by nothing: no `Send complete`, no `Sync outcomes`, no `Retry causes`, no `Compression`, no `Wire-to-ACK`. `HandleBusy`'s send-target branch tags the in-flight chunk `busyAbort`, cancels the timers, clears the send fields inline and logs that one line; it never calls `FinishSending`, and `chunkOutcomes` is reset when the next send starts, so the `busyAbort` tag is never rendered anywhere. Every `aborted: ... + 0 busy` in every capture this repo holds is zero by construction. `OnCombatStart` is the working pattern: it tags `combatAbort` and then calls `FinishSending` for a live send, which is why the combat aborts on our own side (session 8 at 15:51:09 and 16:21:45, session 9 at 22:29:55) all carry full blocks. Same gap on 2026-08-26, where three BUSY aborts to Flamè (23:32:10, 23:40:16, 23:44:39) left no block either. The longest send of the night has no numbers. Still true on main at 42dd257 (2026-09-20).

3. **Sessions to near-converged peers are mostly duplicate, and that is where the send slot goes.** The Kátorri/Katorrí account advertised 13623 tx from 22:30 through 22:55, across the 55 ACKed chunks of send 1 and the 262 of send 2; by 00:22 it read 13681, then 13671 at 00:27 and 13672 at 00:32, across a 404/404 (369 records) and a 366/385 (349 records) session. So roughly 1,035 records were delivered to it between 22:44 and 00:34 for a net move of +49 in what it advertises. That is consistent with about 95% duplicate, with the caveat that the advertised count also moves on the peer's own scans, its duplicate cleanup (it went down twice in the day) and gossip from other members, so it is a reading rather than a measurement. Katorrí on the afternoon: 305 records, 13567 to 13578. On the morning: 422 records plus part of a 705-record session, 13472 to 13462. Heydk-Spirestone on 2026-09-01, 5,388 behind: 511 records, 9454 to 9708, so at most half duplicate. The arithmetic explains it: a peer 1,450 behind with the difference spread over 321 of 335 differing buckets is about 4.5 records per bucket, so whole-bucket resend is around 90% duplicate by construction; at 5,388 behind the same arithmetic predicts about 65%, and Heydk read 50. This is the 2026-08-25 Heydk finding (~96%) at a third peer. Across sessions 6 to 10 and the paste, every send went to a peer within 1,500 of local except Heydk's two, while Strikä-Stormrage (4,949 tx) and Warbird-BurningBlade (2,251) each requested once and were declined, and Tyladori-Dalaran (4,426) and Eltherin-Area52 (1,666) were nudged repeatedly and never requested inside a captured window. The receiver-side `Redundancy from` line is still the missing number; SYNC_RECEIPT is the instrument on file.

4. **The peer that just finished re-takes the slot inside two seconds while declined peers wait.** 2026-09-01: Heydk's second session started at 20:42:30, two seconds after its first ended at 20:42:28, while Flamè had been declined at 20:32:52, 20:37:27 and 20:39:36 and Katorrí at 20:32:32 and 20:41:50; both were declined again at 20:43:27 and 20:43:30. 2026-09-03: Kátorri's 404/404 session ended at 00:27:18 and its next started at 00:27:20. The mechanism is the continuation seam working as designed (post-receive forced HELLO, superset nudge, request), which is exactly why the peer already mid-handshake wins every time. The 2026-08-18 capture recorded the contested-slot case once; this is the third sighting. Russell's post-session cooldown directive is the answer on file, and its prerequisite (#97) has shipped.

5. **Retry-on-silence recovered two lost requests, and the loss signature is unchanged.** Strikä-Stormrage's SYNC_REQUEST arrived as `Could not decompress a WHISPER message from Strikä-Stormrage (452 B)` at 22:52:44 and again at 22:53:04, then whole at 22:53:34 to be declined already-sending. The 20 s and 30 s gaps are the receive-timeout ladder (`nackBackoff`: 20, 30, 45 s) driving the resend branch in `ScheduleReceiveTimeout`, and 452 B is the middle-fragment-lost shape (254 + 198 of a 3-fragment request of about 710 B). Six more across sessions 7 to 9, all 451 to 460 B: Katorrí 460 B at 11:41:12, Aeglos-ArgentDawn 456 B at 15:48:59, Kátorri 452, 452, 451, 451 and 451 B at 22:19:15, 22:33:17, 22:34:49, 22:38:49 and 22:40:49. Every reading since the gate was armed on 2026-08-16 sits in the same 450 to 462 B band: independent single-fragment loss, no bursts, FEC verdict unmoved.

6. **BUSY reason=combat and the combat serve gate are both routine now.** Four `Received BUSY from ... (reason: combat)` on 2026-09-02 (Kátorri at 22:22:34, 22:33:18, 22:34:50 and 22:55:27) plus four on 2026-08-26/27 (Flamè three times, Raee-Nesingwary once), and six `Declined sync from ... (in combat) - sent BUSY` on 2026-09-02 (Katorrí 16:10:59; Kátorri 22:30:55, 22:35:17, 22:39:39, 22:41:09; Voxle 22:41:17). Three of the evening's Kátorri BUSYs arrived while we were not sending to that character, one to two seconds after one of their requests died on the wire: their request set `receiving` on their side, never reached us, and their combat entry BUSYed a session we never knew about. That is a reading of `OnCombatStart` (BUSY to both partners of any live session), not something observed on their client.

7. **Two CTL stalls, both on the far side of a loading screen, both recovered.** Session 8: `Loading screen detected` at 15:49:49, `Zone cooldown complete` at 15:50:00, then eight `CTL low (avail=?, need=400 ...)` deferrals, a second loading screen, a NACK from Flameus at `CTL.avail=-602`, two more deferrals at `avail=0`, and `CTL recovered: 12 deferrals, 0 overlapped, stall 19.0s, min avail 0, recovery 978 B/s (zone/combat pause overlapped; stall includes dead time)` at 15:50:19. Then at 16:17:50, after another loading screen, seven deferrals all `avail=?` and `CTL recovered: 7 deferrals, 0 overlapped, stall 7.0s, min avail ?, recovery ? B/s`. The `?` is how `SendNextChunk` renders a negative meter (its `availStr` prints `?` when the sampled `avail` is below zero), and the NACK line shows the value: ChatThrottleLib was in debt coming out of the loading screen. Zero overlapped timers on both, so this is not the timer-chain multiplication the adaptive-backoff memory hypothesises, and its decision rule says defer. The `CTL still starved at send end` line did not fire here (both episodes recovered before their sends ended); it was first seen live on 2026-09-19 and #50 closed on it.

8. **The first request after a reload costs five seconds of prep at 10 to 17 FPS.** `Prep complete for Kátorri-Stormrage: 15064 examined, 307 selected, 30 tick(s), 5.38s` against 0.97 to 1.02 s for every later prep in the window and 0.34 to 0.74 s across the audit sessions. `FPS low (10)` at 22:44:56 and `(17)` at 22:45:10, the bank scan taking 6 s at 22:45:13, and ChatThrottleLib still refilling: `CTL.avail=869` at chunk 1, 441 after it, 434 at chunk 12, against `need=400`, with no deferral. Consistent with the 2026-08-25 raid-load reading (27 ticks over 5.40 s at 10 FPS).

9. **The superset nudge invites a request the sender then refuses.** 22:51:28: `HELLO round Voxle: verdict=superset-nudge`, `Nudged behind peer Voxle to pull`, `RECV WHISPER from Voxle (SYNC_REQUEST)` in the same second, `Declined sync from Voxle (already sending to Kátorri-Stormrage)`, `Sent BUSY to Voxle`. Voxle is now on a 30 s BUSY cooldown for doing what it was told. Same shape on 2026-09-01 for Flamè (nudged at 20:37:36 and 20:39:36, declined in the same second the second time). The nudge site does not check `syncState.sending`. A design observation rather than a defect: the request would be refused either way, but the nudge costs a whisper each way and a cooldown.

10. **Two small things worth not rediscovering.** An alt swap reads as an offline abort: `Blocked whisper to offline player: Kátorri-Stormrage` at 22:46:18, `Target Kátorri-Stormrage went offline, aborting send`, then Katorrí-Stormrage's HELLO at 22:46:57 advertising the same 13623. Three spellings of that account appear in one evening (Katorrí, Kátorri, and Katorri at 22:24:32), and `capLastTranche` and `peerBusyUntil` are keyed per character, so one install carries several tranche records and a BUSY cooldown on one alt does not cover the next. Not diagnosed. And the 22:55:55 round line carries no `buckets=` because `Post-scan cleanup: removed 7 duplicate record(s)` at 22:55:16 moved the count from 15081 to 15076, and `PeekBucketHashes` returns nil on a cold cache rather than walking history on an inbound HELLO, which is the #90 design.

Health readings from the same window. Kátorri send 1: `46 on 1st, 9 on 2nd, chunkFail=13.8%, p_frag=7.4%, n=1.9`, wire-to-ACK 0.26/0.55/0.75 s, compression 60/65/70% of raw. Soulcialist: compression 60/66/70%, `n=1.9`, 71 chunks over one fragment. `0 CTL deferrals, longest stall 0.0s` on both summaries. Within Kátorri send 2, nine retries in the first 50 s, ten more between 22:51:40 and 22:52:49, and none across chunks 24 to 66 or 107 to 263: route quality swung inside one session, which the route-variance memory already records. The epoch-0 bucket (`1969-12-31 19:00`, #93) heads all three `Differing dates` lists. Sort side: the 21:46 run in session 9 was the second live bags-in-sort run (`bags:3/61(fill=0,spill=5,...)`, 3 passes, 49 ops, `Sort bags: 5 deposit(s) issued, 0 skipped`, converged), and the paste's two previews read `bags:0/58(... ignored=17,bound=41 ...)`; both superseded by the #141 merge and `docs/sort-logs/2026-08-27-bags-near-full-overflow.md`.

## Open questions for the next investigation pass

- Stale ACKs are receiver-liveness evidence and the ladder ignores them. Instrument first: a `staleAcks=N` term on the `Retry causes` line separates late from lost without hand-counting. Only after a capture with that number, a policy: a stale ACK for the previous chunk arriving mid-ladder resets or stretches patience instead of counting toward `MAX_RETRIES`. `ACK_TIMEOUT` and `MAX_RETRIES` move together (#92), and no lever ships in the same capture window as another.
- **The BUSY-abort summary gap (finding 2) is CLOSED: #202, v0.41.9, 2026-09-26.** The fix was `OnCombatStart`'s shape as predicted, tag then `FinishSending`, and the bidirectional-check ordering the issue asked to pin is pinned. One thing this record did not know, and it is the more useful half. **The per-chunk tag could not have carried the abort even once the block started being written.** `sendChunkIndex` advances when a chunk is issued and `HandleAck` settles the acked chunk to `ok` without advancing it, so from each ACK until the next issue, at least the 1.0s gap floor against a 0.2 to 0.5s wire-to-ACK, nothing is on the wire and the `outcome == "pending"` guard tags nothing. A BUSY in that window, which is most of every chunk cycle, would have printed an all-zero abort histogram under a `Send complete` heading: the same zero this finding is about, arrived at a different way. So the session's cause is now stated in its own clause, `session ended by busy at chunk N/M`, and the histogram goes on counting chunks. **Read `+ 0 combat +` and `+ 0 zone +` in this record the same way**: those paths share the guard, so their zeros are not evidence either. What the next capture settles is whether the verdict clause names BUSY on sessions like the 22:55:27 one, against this record's four.
- SYNC_RECEIPT was the instrument that settles finding 3, and it SHIPPED as #237, v0.41.6, on 2026-09-24, log-only. This line said "still unfiled" until 2026-09-26; it was filed and built in between. Finding 3 now waits on calendar time rather than on a build: two receipts from real guild play are what #96 and #110 are parked on.
- The post-session cooldown directive now has its prerequisite shipped. Finding 4 is its third sighting.
- Should the superset nudge be suppressed while `sending`? It invites a request the serve gate refuses.
- Per-character tranche and cooldown keys on a multi-alt account: is an account-level identity available on the wire, or is per-character correct as is?

## Raw log

Pasted from the in-game `/gbl logs` master pop-up (all three channels interleaved) just after 22:55:55 on 2026-09-02. Newest entries first, as displayed. Reproduced verbatim; the three `Differing dates:` lines are kept whole.

```text
[22:55:55] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=sent peer=v0.38.1 remote=13623tx local=15076tx hash=3021430376/1884250325
[22:55:55] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15076, hash: 3021430376)
[22:55:55] [SYNC] [INFO] RECV GUILD from Kátorri-Stormrage (HELLO)
[22:55:27] [SYNC] [INFO] Kátorri-Stormrage busy - aborting send
[22:55:27] [SYNC] [INFO] Received BUSY from Kátorri-Stormrage (reason: combat)
[22:55:27] [SYNC] [INFO] RECV WHISPER from Kátorri-Stormrage (BUSY)
[22:55:27] [SYNC] [INFO] Chunk 263 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:55:26] [SYNC] [INFO] Chunk 262 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:55:25] [SYNC] [INFO] Chunk 261 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:55:24] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 260/436, 0.7s RTT, wire-to-ACK=0.71s
[22:55:24] [SYNC] [INFO] Chunk 260 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:55:24] [SYNC] [INFO] Sending chunk 260/436 to Kátorri-Stormrage (1 records, 338->230 bytes, 68% of raw, CTL.avail=3731, CTLq=0/0/0, gap=1.00s)
[22:55:23] [SYNC] [INFO] Chunk 259 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:55:22] [SYNC] [INFO] Chunk 258 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:55:21] [SYNC] [INFO] Chunk 257 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:55:20] [SYNC] [INFO] Chunk 256 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:55:20] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 5s)
[22:55:19] [SYNC] [INFO] Chunk 255 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:55:18] [SYNC] [INFO] Chunk 254 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:55:17] [SYNC] [INFO] Chunk 253 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:55:16] [SYNC] [INFO] Chunk 252 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:55:16] [SYSTEM] [INFO] Post-scan cleanup: removed 7 duplicate record(s)
[22:55:15] [SYNC] [INFO] Chunk 251 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:55:14] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 250/436, 0.4s RTT, wire-to-ACK=0.42s
[22:55:14] [SYNC] [INFO] Chunk 250 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:55:14] [SYNC] [INFO] Sending chunk 250/436 to Kátorri-Stormrage (1 records, 338->231 bytes, 68% of raw, CTL.avail=3730, CTLq=0/0/0, gap=1.02s)
[22:55:13] [SYNC] [INFO] Chunk 249 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:55:11] [SYNC] [INFO] Chunk 248 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:55:10] [SYNC] [INFO] Chunk 247 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:55:09] [SYNC] [INFO] Chunk 246 transmitted (0.00s queue-to-wire, CTL.avail=3734)
[22:55:08] [SYNC] [INFO] Chunk 245 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:55:07] [SYNC] [INFO] Chunk 244 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:55:06] [SYNC] [INFO] Chunk 243 transmitted (0.00s queue-to-wire, CTL.avail=3733)
[22:55:05] [SYNC] [INFO] Chunk 242 transmitted (0.00s queue-to-wire, CTL.avail=3733)
[22:55:04] [SYNC] [INFO] Chunk 241 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:55:04] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 240/436, 0.7s RTT, wire-to-ACK=0.70s
[22:55:03] [SYNC] [INFO] Chunk 240 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:55:03] [SYNC] [INFO] Sending chunk 240/436 to Kátorri-Stormrage (1 records, 336->229 bytes, 68% of raw, CTL.avail=3733, CTLq=0/0/0, gap=1.00s)
[22:55:02] [SYNC] [INFO] Chunk 239 transmitted (0.00s queue-to-wire, CTL.avail=3733)
[22:55:01] [SYNC] [INFO] Chunk 238 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:55:00] [SYNC] [INFO] Chunk 237 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:59] [SYNC] [INFO] Chunk 236 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:58] [SYNC] [INFO] Chunk 235 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:57] [SYNC] [INFO] Chunk 234 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:56] [SYNC] [INFO] Chunk 233 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:55] [SYNC] [INFO] Chunk 232 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:54:54] [SYNC] [INFO] Chunk 231 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:54] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 230/436, 0.6s RTT, wire-to-ACK=0.60s
[22:54:53] [SYNC] [INFO] Chunk 230 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:53] [SYNC] [INFO] Sending chunk 230/436 to Kátorri-Stormrage (1 records, 337->230 bytes, 68% of raw, CTL.avail=3730, CTLq=0/0/0, gap=1.00s)
[22:54:52] [SYNC] [INFO] Chunk 229 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:51] [SYNC] [INFO] Chunk 228 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:50] [SYNC] [INFO] Chunk 227 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:49] [SYNC] [INFO] Chunk 226 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:48] [SYNC] [INFO] Chunk 225 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:47] [SYNC] [INFO] Chunk 224 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:46] [SYNC] [INFO] Chunk 223 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:45] [SYNC] [INFO] Chunk 222 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:44] [SYNC] [INFO] Chunk 221 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:44] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 220/436, 0.4s RTT, wire-to-ACK=0.43s
[22:54:43] [SYNC] [INFO] Chunk 220 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:43] [SYNC] [INFO] Sending chunk 220/436 to Kátorri-Stormrage (1 records, 336->229 bytes, 68% of raw, CTL.avail=3731, CTLq=0/0/0, gap=1.00s)
[22:54:42] [SYNC] [INFO] Chunk 219 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:41] [SYNC] [INFO] Chunk 218 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:40] [SYNC] [INFO] Chunk 217 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:54:39] [SYNC] [INFO] Chunk 216 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:38] [SYNC] [INFO] Chunk 215 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:54:37] [SYNC] [INFO] Chunk 214 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:36] [SYNC] [INFO] Chunk 213 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:35] [SYNC] [INFO] Chunk 212 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:34] [SYNC] [INFO] Chunk 211 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:34] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 210/436, 0.5s RTT, wire-to-ACK=0.50s
[22:54:33] [SYNC] [INFO] Chunk 210 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:54:33] [SYNC] [INFO] Sending chunk 210/436 to Kátorri-Stormrage (1 records, 339->234 bytes, 69% of raw, CTL.avail=3728, CTLq=0/0/0, gap=1.00s)
[22:54:32] [SYNC] [INFO] Chunk 209 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:31] [SYNC] [INFO] Chunk 208 transmitted (0.00s queue-to-wire, CTL.avail=3723)
[22:54:30] [SYNC] [INFO] Chunk 207 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:29] [SYNC] [INFO] Chunk 206 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:28] [SYNC] [INFO] Chunk 205 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:54:27] [SYNC] [INFO] Chunk 204 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:26] [SYNC] [INFO] Chunk 203 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:25] [SYNC] [INFO] Chunk 202 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:24] [SYNC] [INFO] Chunk 201 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:54:24] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 200/436, 0.5s RTT, wire-to-ACK=0.53s
[22:54:23] [SYNC] [INFO] Chunk 200 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:23] [SYNC] [INFO] Sending chunk 200/436 to Kátorri-Stormrage (1 records, 338->231 bytes, 68% of raw, CTL.avail=3728, CTLq=0/0/0, gap=1.01s)
[22:54:22] [SYNC] [INFO] Chunk 199 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:21] [SYNC] [INFO] Chunk 198 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:54:20] [SYNC] [INFO] Chunk 197 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:19] [SYNC] [INFO] Chunk 196 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:18] [SYNC] [INFO] Chunk 195 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:54:17] [SYNC] [INFO] Chunk 194 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:16] [SYNC] [INFO] Chunk 193 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:15] [SYNC] [INFO] Chunk 192 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:14] [SYNC] [INFO] Chunk 191 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:14] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 190/436, 0.6s RTT, wire-to-ACK=0.63s
[22:54:13] [SYNC] [INFO] Chunk 190 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:13] [SYNC] [INFO] Sending chunk 190/436 to Kátorri-Stormrage (1 records, 336->229 bytes, 68% of raw, CTL.avail=3729, CTLq=0/0/0, gap=1.00s)
[22:54:12] [SYNC] [INFO] Chunk 189 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:11] [SYNC] [INFO] Chunk 188 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:10] [SYNC] [INFO] Chunk 187 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:09] [SYNC] [INFO] Chunk 186 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:54:08] [SYNC] [INFO] Chunk 185 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:07] [SYNC] [INFO] Chunk 184 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:06] [SYNC] [INFO] Chunk 183 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:54:05] [SYNC] [INFO] Chunk 182 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:04] [SYNC] [INFO] Chunk 181 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:04] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 180/436, 0.6s RTT, wire-to-ACK=0.60s
[22:54:03] [SYNC] [INFO] Chunk 180 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:03] [SYNC] [INFO] Sending chunk 180/436 to Kátorri-Stormrage (1 records, 336->229 bytes, 68% of raw, CTL.avail=3731, CTLq=0/0/0, gap=1.00s)
[22:54:02] [SYNC] [INFO] Chunk 179 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:54:01] [SYNC] [INFO] Chunk 178 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:54:00] [SYNC] [INFO] Chunk 177 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:53:59] [SYNC] [INFO] Chunk 176 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:58] [SYNC] [INFO] Chunk 175 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:53:57] [SYNC] [INFO] Chunk 174 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:56] [SYNC] [INFO] Chunk 173 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:55] [SYNC] [INFO] Chunk 172 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:54] [SYNC] [INFO] Chunk 171 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:54] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 170/436, 0.5s RTT, wire-to-ACK=0.53s
[22:53:53] [SYNC] [INFO] Chunk 170 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:53:53] [SYNC] [INFO] Sending chunk 170/436 to Kátorri-Stormrage (1 records, 336->233 bytes, 69% of raw, CTL.avail=3727, CTLq=0/0/0, gap=1.00s)
[22:53:52] [SYNC] [INFO] Chunk 169 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:53:51] [SYNC] [INFO] Chunk 168 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:50] [SYNC] [INFO] Chunk 167 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:53:49] [SYNC] [INFO] Chunk 166 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:48] [SYNC] [INFO] Chunk 165 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:47] [SYNC] [INFO] Chunk 164 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:46] [SYNC] [INFO] Chunk 163 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:45] [SYNC] [INFO] Chunk 162 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:44] [SYNC] [INFO] Chunk 161 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:44] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 160/436, 0.7s RTT, wire-to-ACK=0.67s
[22:53:43] [SYNC] [INFO] Chunk 160 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:43] [SYNC] [INFO] Sending chunk 160/436 to Kátorri-Stormrage (1 records, 337->230 bytes, 68% of raw, CTL.avail=3730, CTLq=0/0/0, gap=1.00s)
[22:53:42] [SYNC] [INFO] Chunk 159 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:41] [SYNC] [INFO] Chunk 158 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:40] [SYNC] [INFO] Chunk 157 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:39] [SYNC] [INFO] Chunk 156 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:38] [SYNC] [INFO] Chunk 155 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:37] [SYNC] [INFO] Chunk 154 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:36] [SYNC] [INFO] Chunk 153 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:35] [SYNC] [INFO] Chunk 152 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:34] [SYNC] [INFO] Sent BUSY to Strikä-Stormrage
[22:53:34] [SYNC] [INFO] Declined sync from Strikä-Stormrage (already sending to Kátorri-Stormrage)
[22:53:34] [SYNC] [INFO] RECV WHISPER from Strikä-Stormrage (SYNC_REQUEST)
[22:53:34] [SYNC] [INFO] Chunk 151 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:53:34] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 150/436, 0.5s RTT, wire-to-ACK=0.53s
[22:53:33] [SYNC] [INFO] Chunk 150 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:53:33] [SYNC] [INFO] Sending chunk 150/436 to Kátorri-Stormrage (1 records, 336->229 bytes, 68% of raw, CTL.avail=3729, CTLq=0/0/0, gap=1.01s)
[22:53:32] [SYNC] [INFO] Chunk 149 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:31] [SYNC] [INFO] Chunk 148 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:30] [SYNC] [INFO] Chunk 147 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:29] [SYNC] [INFO] Chunk 146 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:28] [SYNC] [INFO] Chunk 145 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:27] [SYNC] [INFO] Chunk 144 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:26] [SYNC] [INFO] Chunk 143 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:25] [SYNC] [INFO] Chunk 142 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:24] [SYNC] [INFO] Chunk 141 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:24] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 140/436, 0.4s RTT, wire-to-ACK=0.40s
[22:53:23] [SYNC] [INFO] Chunk 140 transmitted (0.00s queue-to-wire, CTL.avail=3704)
[22:53:23] [SYNC] [INFO] Sending chunk 140/436 to Kátorri-Stormrage (1 records, 337->230 bytes, 68% of raw, CTL.avail=3894, CTLq=0/0/0, gap=1.00s)
[22:53:22] [SYNC] [INFO] Chunk 139 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:21] [SYNC] [INFO] Chunk 138 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:20] [SYNC] [INFO] Chunk 137 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:19] [SYNC] [INFO] Chunk 136 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:18] [SYNC] [INFO] Chunk 135 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:53:17] [SYNC] [INFO] Chunk 134 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:53:16] [SYNC] [INFO] Chunk 133 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:53:15] [SYNC] [INFO] Chunk 132 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:14] [SYNC] [INFO] Chunk 131 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:14] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 130/436, 0.6s RTT, wire-to-ACK=0.63s
[22:53:13] [SYNC] [INFO] Chunk 130 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:13] [SYNC] [INFO] Sending chunk 130/436 to Kátorri-Stormrage (1 records, 338->231 bytes, 68% of raw, CTL.avail=3729, CTLq=0/0/0, gap=1.00s)
[22:53:12] [SYNC] [INFO] Chunk 129 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:11] [SYNC] [INFO] Chunk 128 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:10] [SYNC] [INFO] Chunk 127 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:53:09] [SYNC] [INFO] Chunk 126 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:08] [SYNC] [INFO] Chunk 125 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:07] [SYNC] [INFO] Chunk 124 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:53:06] [SYNC] [INFO] Chunk 123 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:05] [SYNC] [INFO] Chunk 122 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:53:04] [SYNC] [WARN] Could not decompress a WHISPER message from Strikä-Stormrage (452 B); likely a lost or corrupt fragment
[22:53:04] [SYNC] [INFO] Chunk 121 transmitted (0.00s queue-to-wire, CTL.avail=3734)
[22:53:04] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 120/436, 0.7s RTT, wire-to-ACK=0.67s
[22:53:03] [SYNC] [INFO] Chunk 120 transmitted (0.00s queue-to-wire, CTL.avail=3733)
[22:53:03] [SYNC] [INFO] Sending chunk 120/436 to Kátorri-Stormrage (1 records, 336->227 bytes, 67% of raw, CTL.avail=3732, CTLq=0/0/0, gap=1.00s)
[22:53:02] [SYNC] [INFO] Chunk 119 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:53:01] [SYNC] [INFO] Chunk 118 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:53:00] [SYNC] [INFO] Chunk 117 transmitted (0.00s queue-to-wire, CTL.avail=3647)
[22:52:59] [SYNC] [INFO] Chunk 116 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:52:58] [SYNC] [INFO] Chunk 115 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:52:57] [SYNC] [INFO] Chunk 114 transmitted (0.00s queue-to-wire, CTL.avail=3653)
[22:52:56] [SYNC] [INFO] Chunk 113 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:52:55] [SYNC] [INFO] Chunk 112 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:52:54] [SYNC] [INFO] Chunk 111 transmitted (0.00s queue-to-wire, CTL.avail=3722)
[22:52:54] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 110/436, 0.6s RTT, wire-to-ACK=0.63s
[22:52:53] [SYNC] [INFO] Chunk 110 transmitted (0.00s queue-to-wire, CTL.avail=3725)
[22:52:53] [SYNC] [INFO] Sending chunk 110/436 to Kátorri-Stormrage (1 records, 340->235 bytes, 69% of raw, CTL.avail=3625, CTLq=0/0/0, gap=1.00s)
[22:52:52] [SYNC] [INFO] Chunk 109 transmitted (0.00s queue-to-wire, CTL.avail=3625)
[22:52:51] [SYNC] [INFO] Chunk 108 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:52:50] [SYNC] [INFO] Chunk 107 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:52:49] [SYNC] [INFO] Chunk 106 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:52:49] [SYNC] [WARN] ACK timeout, retrying chunk 106 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:52:46] [SYNC] [INFO] Chunk 106 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:52:45] [SYNC] [INFO] Chunk 105 transmitted (0.00s queue-to-wire, CTL.avail=3650)
[22:52:44] [SYNC] [WARN] Could not decompress a WHISPER message from Strikä-Stormrage (452 B); likely a lost or corrupt fragment
[22:52:44] [SYNC] [INFO] Chunk 104 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:52:44] [SYNC] [INFO] Sent HELLO (tx: 15081, hash: 3232344604)
[22:52:43] [SYNC] [INFO] Chunk 103 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:52:42] [SYNC] [INFO] Chunk 102 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:52:42] [SYNC] [WARN] ACK timeout, retrying chunk 102 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:52:39] [SYNC] [INFO] Chunk 102 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:52:38] [SYNC] [INFO] Chunk 101 transmitted (0.00s queue-to-wire, CTL.avail=3649)
[22:52:38] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 100/436, 0.7s RTT, wire-to-ACK=0.68s
[22:52:37] [SYNC] [INFO] Chunk 100 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:52:37] [SYNC] [INFO] Sending chunk 100/436 to Kátorri-Stormrage (1 records, 422->272 bytes, 64% of raw, CTL.avail=3806, CTLq=0/0/0, gap=3.01s)
[22:52:37] [SYNC] [WARN] ACK timeout, retrying chunk 100 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:52:34] [SYNC] [INFO] Chunk 100 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:52:34] [SYNC] [INFO] Sending chunk 100/436 to Kátorri-Stormrage (1 records, 422->272 bytes, 64% of raw, CTL.avail=3636, CTLq=0/0/0, gap=1.00s)
[22:52:33] [SYNC] [INFO] Chunk 99 transmitted (0.00s queue-to-wire, CTL.avail=3636)
[22:52:32] [SYNC] [INFO] Chunk 98 transmitted (0.00s queue-to-wire, CTL.avail=3636)
[22:52:31] [SYNC] [INFO] Chunk 97 transmitted (0.00s queue-to-wire, CTL.avail=3649)
[22:52:30] [SYNC] [INFO] Chunk 96 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:52:29] [SYNC] [INFO] Chunk 95 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:52:28] [SYNC] [INFO] Chunk 94 transmitted (0.00s queue-to-wire, CTL.avail=3651)
[22:52:27] [SYNC] [INFO] Chunk 93 transmitted (0.00s queue-to-wire, CTL.avail=3652)
[22:52:26] [SYNC] [INFO] Chunk 92 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:52:25] [SYNC] [INFO] Chunk 91 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:52:25] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 90/436, 0.7s RTT, wire-to-ACK=0.67s
[22:52:24] [SYNC] [INFO] Chunk 90 transmitted (0.00s queue-to-wire, CTL.avail=3655)
[22:52:24] [SYNC] [INFO] Sending chunk 90/436 to Kátorri-Stormrage (1 records, 426->263 bytes, 61% of raw, CTL.avail=3638, CTLq=0/0/0, gap=1.02s)
[22:52:23] [SYNC] [INFO] Chunk 89 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:52:22] [SYNC] [INFO] Chunk 88 transmitted (0.00s queue-to-wire, CTL.avail=3654)
[22:52:22] [SYNC] [WARN] ACK timeout, retrying chunk 88 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:52:19] [SYNC] [INFO] Chunk 88 transmitted (0.00s queue-to-wire, CTL.avail=3654)
[22:52:18] [SYNC] [INFO] Chunk 87 transmitted (0.00s queue-to-wire, CTL.avail=3647)
[22:52:17] [SYNC] [INFO] Chunk 86 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:52:16] [SYNC] [INFO] Chunk 85 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:52:15] [SYNC] [INFO] Chunk 84 transmitted (0.00s queue-to-wire, CTL.avail=3634)
[22:52:15] [SYNC] [WARN] ACK timeout, retrying chunk 84 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:52:12] [SYNC] [INFO] Chunk 84 transmitted (0.00s queue-to-wire, CTL.avail=3634)
[22:52:11] [SYNC] [INFO] Chunk 83 transmitted (0.00s queue-to-wire, CTL.avail=3636)
[22:52:10] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:52:09] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:52:09] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:52:06] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:52:06] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 80/436, 0.6s RTT, wire-to-ACK=0.60s
[22:52:05] [SYNC] [INFO] Chunk 80 transmitted (0.00s queue-to-wire, CTL.avail=3631)
[22:52:05] [SYNC] [INFO] Sending chunk 80/436 to Kátorri-Stormrage (1 records, 428->287 bytes, 67% of raw, CTL.avail=3638, CTLq=0/0/0, gap=1.00s)
[22:52:04] [SYNC] [INFO] Chunk 79 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:52:03] [SYNC] [INFO] Chunk 78 transmitted (0.00s queue-to-wire, CTL.avail=3652)
[22:52:02] [SYNC] [INFO] Chunk 77 transmitted (0.00s queue-to-wire, CTL.avail=3647)
[22:52:01] [SYNC] [INFO] Chunk 76 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:52:01] [SYNC] [WARN] ACK timeout, retrying chunk 76 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:51:58] [SYNC] [INFO] Chunk 76 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:51:57] [SYNC] [INFO] Chunk 75 transmitted (0.00s queue-to-wire, CTL.avail=3636)
[22:51:56] [SYNC] [INFO] Chunk 74 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:51:55] [SYNC] [INFO] Chunk 73 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:51:54] [SYNC] [INFO] Chunk 72 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:51:53] [SYNC] [INFO] Chunk 71 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:51:53] [SYNC] [WARN] ACK timeout, retrying chunk 71 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:51:50] [SYNC] [INFO] Chunk 71 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:51:50] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 70/436, 0.6s RTT, wire-to-ACK=0.64s
[22:51:49] [SYNC] [INFO] Chunk 70 transmitted (0.00s queue-to-wire, CTL.avail=3648)
[22:51:49] [SYNC] [INFO] Sending chunk 70/436 to Kátorri-Stormrage (1 records, 422->270 bytes, 63% of raw, CTL.avail=3647, CTLq=0/0/0, gap=1.01s)
[22:51:48] [SYNC] [INFO] Chunk 69 transmitted (0.00s queue-to-wire, CTL.avail=3647)
[22:51:48] [SYNC] [WARN] ACK timeout, retrying chunk 69 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:51:45] [SYNC] [INFO] Chunk 69 transmitted (0.00s queue-to-wire, CTL.avail=3647)
[22:51:44] [SYNC] [INFO] Chunk 68 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:51:43] [SYNC] [INFO] Chunk 67 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:51:43] [SYNC] [WARN] ACK timeout, retrying chunk 67 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:51:40] [SYNC] [INFO] Chunk 67 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:51:39] [SYNC] [INFO] Chunk 66 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:51:38] [SYNC] [INFO] Chunk 65 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:51:37] [SYNC] [INFO] Chunk 64 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:51:36] [SYNC] [INFO] Chunk 63 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:51:35] [SYNC] [INFO] Chunk 62 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:34] [SYNC] [INFO] Chunk 61 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:34] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 60/436, 0.6s RTT, wire-to-ACK=0.63s
[22:51:33] [SYNC] [INFO] Chunk 60 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:33] [SYNC] [INFO] Sending chunk 60/436 to Kátorri-Stormrage (1 records, 336->229 bytes, 68% of raw, CTL.avail=3730, CTLq=0/0/0, gap=1.00s)
[22:51:32] [SYNC] [INFO] Chunk 59 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:31] [SYNC] [INFO] Chunk 58 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:30] [SYNC] [INFO] Chunk 57 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:29] [SYNC] [INFO] Chunk 56 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:28] [SYNC] [INFO] Sent BUSY to Voxle
[22:51:28] [SYNC] [INFO] Declined sync from Voxle (already sending to Kátorri-Stormrage)
[22:51:28] [SYNC] [INFO] RECV WHISPER from Voxle (SYNC_REQUEST)
[22:51:28] [SYNC] [INFO] Chunk 55 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:51:28] [SYNC] [INFO] HELLO round Voxle: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=12929tx local=15081tx hash=3232344604/2089225028 buckets=335
[22:51:28] [SYNC] [INFO] Nudged behind peer Voxle to pull (superset, hash-gate bypass)
[22:51:28] [SYNC] [INFO] Sent HELLO reply to Voxle (tx: 15081, hash: 3232344604)
[22:51:28] [SYNC] [INFO] RECV GUILD from Voxle (HELLO)
[22:51:27] [SYNC] [INFO] Chunk 54 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:26] [SYNC] [INFO] Chunk 53 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:51:25] [SYNC] [INFO] Chunk 52 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:51:24] [SYNC] [INFO] Chunk 51 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:51:24] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 50/436, 0.7s RTT, wire-to-ACK=0.68s
[22:51:23] [SYNC] [INFO] Chunk 50 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:23] [SYNC] [INFO] Sending chunk 50/436 to Kátorri-Stormrage (1 records, 337->230 bytes, 68% of raw, CTL.avail=3730, CTLq=0/0/0, gap=1.00s)
[22:51:22] [SYNC] [INFO] Chunk 49 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:21] [SYNC] [INFO] Chunk 48 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:51:20] [SYNC] [INFO] Chunk 47 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:51:19] [SYNC] [INFO] Chunk 46 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:51:18] [SYNC] [INFO] Chunk 45 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:17] [SYNC] [INFO] Chunk 44 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:51:16] [SYNC] [INFO] Chunk 43 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:15] [SYNC] [INFO] Chunk 42 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:14] [SYNC] [INFO] Chunk 41 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:13] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 40/436, 0.6s RTT, wire-to-ACK=0.62s
[22:51:13] [SYNC] [INFO] Chunk 40 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:13] [SYNC] [INFO] Sending chunk 40/436 to Kátorri-Stormrage (1 records, 335->230 bytes, 68% of raw, CTL.avail=3730, CTLq=0/0/0, gap=1.00s)
[22:51:12] [SYNC] [INFO] Chunk 39 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:51:11] [SYNC] [INFO] Chunk 38 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:10] [SYNC] [INFO] Chunk 37 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:09] [SYNC] [INFO] Chunk 36 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:51:08] [SYNC] [INFO] Chunk 35 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:51:07] [SYNC] [INFO] Chunk 34 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:51:06] [SYNC] [INFO] Chunk 33 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:51:05] [SYNC] [INFO] Chunk 32 transmitted (0.00s queue-to-wire, CTL.avail=3729)
[22:51:04] [SYNC] [INFO] Chunk 31 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:51:03] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 30/436, 0.6s RTT, wire-to-ACK=0.63s
[22:51:03] [SYNC] [INFO] Chunk 30 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:03] [SYNC] [INFO] Sending chunk 30/436 to Kátorri-Stormrage (1 records, 335->229 bytes, 68% of raw, CTL.avail=3732, CTLq=0/0/0, gap=1.01s)
[22:51:02] [SYNC] [INFO] Chunk 29 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:51:01] [SYNC] [INFO] Chunk 28 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:51:00] [SYNC] [INFO] Chunk 27 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:50:59] [SYNC] [INFO] Chunk 26 transmitted (0.00s queue-to-wire, CTL.avail=3733)
[22:50:58] [SYNC] [INFO] Chunk 25 transmitted (0.00s queue-to-wire, CTL.avail=3733)
[22:50:57] [SYNC] [INFO] Chunk 24 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:50:56] [SYNC] [INFO] Chunk 23 transmitted (0.00s queue-to-wire, CTL.avail=3653)
[22:50:56] [SYNC] [WARN] ACK timeout, retrying chunk 23 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:53] [SYNC] [INFO] Chunk 23 transmitted (0.00s queue-to-wire, CTL.avail=3653)
[22:50:52] [SYNC] [INFO] Chunk 22 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:50:51] [SYNC] [INFO] Chunk 21 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:50:50] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 20/436, 0.5s RTT, wire-to-ACK=0.47s
[22:50:50] [SYNC] [INFO] Chunk 20 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:50:50] [SYNC] [INFO] Sending chunk 20/436 to Kátorri-Stormrage (1 records, 426->278 bytes, 65% of raw, CTL.avail=3640, CTLq=0/0/0, gap=3.00s)
[22:50:50] [SYNC] [WARN] ACK timeout, retrying chunk 20 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:47] [SYNC] [INFO] Chunk 20 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:50:47] [SYNC] [INFO] Sending chunk 20/436 to Kátorri-Stormrage (1 records, 426->278 bytes, 65% of raw, CTL.avail=3649, CTLq=0/0/0, gap=1.00s)
[22:50:46] [SYNC] [INFO] Chunk 19 transmitted (0.00s queue-to-wire, CTL.avail=3649)
[22:50:45] [SYNC] [INFO] Chunk 18 transmitted (0.00s queue-to-wire, CTL.avail=3650)
[22:50:45] [SYNC] [WARN] ACK timeout, retrying chunk 18 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:42] [SYNC] [INFO] Chunk 18 transmitted (0.00s queue-to-wire, CTL.avail=3650)
[22:50:41] [SYNC] [INFO] Chunk 17 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:50:40] [SYNC] [INFO] Chunk 16 transmitted (0.00s queue-to-wire, CTL.avail=3653)
[22:50:39] [SYNC] [INFO] Chunk 15 transmitted (0.00s queue-to-wire, CTL.avail=3656)
[22:50:39] [SYNC] [WARN] ACK timeout, retrying chunk 15 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:36] [SYNC] [INFO] Chunk 15 transmitted (0.00s queue-to-wire, CTL.avail=3656)
[22:50:35] [SYNC] [INFO] Chunk 14 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:50:35] [SYNC] [WARN] ACK timeout, retrying chunk 14 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:32] [SYNC] [INFO] Chunk 14 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:50:31] [SYNC] [INFO] Chunk 13 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:50:30] [SYNC] [INFO] Chunk 12 transmitted (0.00s queue-to-wire, CTL.avail=3648)
[22:50:30] [SYNC] [WARN] ACK timeout, retrying chunk 12 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:50:27] [SYNC] [INFO] Chunk 12 transmitted (0.00s queue-to-wire, CTL.avail=3648)
[22:50:26] [SYNC] [INFO] Chunk 11 transmitted (0.00s queue-to-wire, CTL.avail=3655)
[22:50:26] [SYNC] [WARN] ACK timeout, retrying chunk 11 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:50:23] [SYNC] [INFO] Chunk 11 transmitted (0.00s queue-to-wire, CTL.avail=3655)
[22:50:22] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 10/436, 0.5s RTT, wire-to-ACK=0.53s
[22:50:22] [SYNC] [INFO] Chunk 10 transmitted (0.00s queue-to-wire, CTL.avail=3655)
[22:50:22] [SYNC] [INFO] Sending chunk 10/436 to Kátorri-Stormrage (1 records, 424->263 bytes, 62% of raw, CTL.avail=3628, CTLq=0/0/0, gap=1.00s)
[22:50:21] [SYNC] [INFO] Chunk 9 transmitted (0.00s queue-to-wire, CTL.avail=3628)
[22:50:21] [SYNC] [WARN] ACK timeout, retrying chunk 9 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:18] [SYNC] [INFO] Chunk 9 transmitted (0.00s queue-to-wire, CTL.avail=3628)
[22:50:17] [SYNC] [INFO] Chunk 8 transmitted (0.00s queue-to-wire, CTL.avail=3658)
[22:50:16] [SYNC] [INFO] Chunk 7 transmitted (0.00s queue-to-wire, CTL.avail=3734)
[22:50:15] [SYNC] [INFO] Chunk 6 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:50:14] [SYNC] [INFO] Chunk 5 transmitted (0.00s queue-to-wire, CTL.avail=3732)
[22:50:13] [SYNC] [INFO] Chunk 4 transmitted (0.00s queue-to-wire, CTL.avail=3735)
[22:50:12] [SYNC] [INFO] Chunk 3 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:50:11] [SYNC] [INFO] Chunk 2 transmitted (0.00s queue-to-wire, CTL.avail=3648)
[22:50:10] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 1/436, 0.4s RTT, wire-to-ACK=0.43s
[22:50:10] [SYNC] [INFO] Chunk 1 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:50:10] [SYNC] [INFO] Sending chunk 1/436 to Kátorri-Stormrage (1 records, 424->277 bytes, 65% of raw, CTL.avail=3641, CTLq=0/0/0, gap=3.00s)
[22:50:10] [SYNC] [WARN] ACK timeout, retrying chunk 1 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:50:07] [SYNC] [INFO] Chunk 1 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:50:07] [SYNC] [INFO] Sending chunk 1/436 to Kátorri-Stormrage (1 records, 424->277 bytes, 65% of raw, CTL.avail=3616, CTLq=0/0/0)
[22:50:07] [SYNC] [INFO] Sending 391 tx to Kátorri-Stormrage in 436 chunk(s), capped: 320 bucket(s) deferred
[22:50:07] [SYNC] [INFO] Prep complete for Kátorri-Stormrage: 15081 examined, 391 selected, 30 tick(s), 0.98s
[22:50:06] [SYNC] [INFO] Send order newest-first: 2026-09-02 20:00 back to 1969-12-31 19:00
[22:50:06] [SYNC] [INFO] Tranche rotation for Kátorri-Stormrage: 2 in last tranche, 1 unchanged (demoted), 0 still selected
[22:50:06] [SYNC] [INFO] Sending 10514 item tx + 4313 money tx from differing days
[22:50:06] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01-16 01:00, 2026-03-06 01:00, 2026-03-11 20:00, 2026-03-20 20:00, 2026-03-24 20:00, 2026-03-25 02:00, 2026-03-26 20:00, 2026-03-27 14:00, 2026-03-28 14:00, 2026-03-28 20:00, 2026-03-29 14:00, 2026-03-30 20:00, 2026-03-31 08:00, 2026-03-31 14:00, 2026-03-31 20:00, 2026-04-02 20:00, 2026-04-04 20:00, 2026-04-05 02:00, 2026-04-05 14:00, 2026-04-05 20:00, 2026-04-06 20:00, 2026-04-07 02:00, 2026-04-07 08:00, 2026-04-07 14:00, 2026-04-07 20:00, 2026-04-08 14:00, 2026-04-08 20:00, 2026-04-09 20:00, 2026-04-10 02:00, 2026-04-10 08:00, 2026-04-10 14:00, 2026-04-10 20:00, 2026-04-11 02:00, 2026-04-11 08:00, 2026-04-11 14:00, 2026-04-11 20:00, 2026-04-12 02:00, 2026-04-12 08:00, 2026-04-12 14:00, 2026-04-12 20:00, 2026-04-13 08:00, 2026-04-13 14:00, 2026-04-13 20:00, 2026-04-14 02:00, 2026-04-14 08:00, 2026-04-14 14:00, 2026-04-14 20:00, 2026-04-15 02:00, 2026-04-15 08:00, 2026-04-15 14:00, 2026-04-15 20:00, 2026-04-16 02:00, 2026-04-16 14:00, 2026-04-16 20:00, 2026-04-17 08:00, 2026-04-17 14:00, 2026-04-17 20:00, 2026-04-18 02:00, 2026-04-18 08:00, 2026-04-18 14:00, 2026-04-18 20:00, 2026-04-19 02:00, 2026-04-19 08:00, 2026-04-19 14:00, 2026-04-19 20:00, 2026-04-20 02:00, 2026-04-20 14:00, 2026-04-20 20:00, 2026-04-21 14:00, 2026-04-21 20:00, 2026-04-22 02:00, 2026-04-22 08:00, 2026-04-22 14:00, 2026-04-22 20:00, 2026-04-23 02:00, 2026-04-23 08:00, 2026-04-23 14:00, 2026-04-23 20:00, 2026-04-24 08:00, 2026-04-24 14:00, 2026-04-24 20:00, 2026-04-25 02:00, 2026-04-25 08:00, 2026-04-25 14:00, 2026-04-25 20:00, 2026-04-26 02:00, 2026-04-26 14:00, 2026-04-26 20:00, 2026-04-27 08:00, 2026-04-27 14:00, 2026-04-27 20:00, 2026-04-28 08:00, 2026-04-28 14:00, 2026-04-28 20:00, 2026-04-29 02:00, 2026-04-29 08:00, 2026-04-29 14:00, 2026-04-29 20:00, 2026-04-30 14:00, 2026-04-30 20:00, 2026-05-01 08:00, 2026-05-01 20:00, 2026-05-02 02:00, 2026-05-02 20:00, 2026-05-03 08:00, 2026-05-03 14:00, 2026-05-03 20:00, 2026-05-04 02:00, 2026-05-04 08:00, 2026-05-04 14:00, 2026-05-04 20:00, 2026-05-05 02:00, 2026-05-05 08:00, 2026-05-05 14:00, 2026-05-05 20:00, 2026-05-06 02:00, 2026-05-06 08:00, 2026-05-06 14:00, 2026-05-06 20:00, 2026-05-07 20:00, 2026-05-08 02:00, 2026-05-08 08:00, 2026-05-08 14:00, 2026-05-08 20:00, 2026-05-09 08:00, 2026-05-09 14:00, 2026-05-09 20:00, 2026-05-10 14:00, 2026-05-10 20:00, 2026-05-11 02:00, 2026-05-11 08:00, 2026-05-11 14:00, 2026-05-11 20:00, 2026-05-12 14:00, 2026-05-12 20:00, 2026-05-13 14:00, 2026-05-13 20:00, 2026-05-14 14:00, 2026-05-14 20:00, 2026-05-15 08:00, 2026-05-15 14:00, 2026-05-16 02:00, 2026-05-17 08:00, 2026-05-17 20:00, 2026-05-18 08:00, 2026-05-18 14:00, 2026-05-18 20:00, 2026-05-19 14:00, 2026-05-19 20:00, 2026-05-20 02:00, 2026-05-20 08:00, 2026-05-20 20:00, 2026-05-21 08:00, 2026-05-21 14:00, 2026-05-21 20:00, 2026-05-22 02:00, 2026-05-22 08:00, 2026-05-22 14:00, 2026-05-22 20:00, 2026-05-23 14:00, 2026-05-24 20:00, 2026-05-25 14:00, 2026-05-26 20:00, 2026-05-27 14:00, 2026-05-27 20:00, 2026-05-28 14:00, 2026-05-30 20:00, 2026-05-31 20:00, 2026-06-01 14:00, 2026-06-01 20:00, 2026-06-02 08:00, 2026-06-02 14:00, 2026-06-02 20:00, 2026-06-04 20:00, 2026-06-05 20:00, 2026-06-06 14:00, 2026-06-06 20:00, 2026-06-07 08:00, 2026-06-07 14:00, 2026-06-07 20:00, 2026-06-08 14:00, 2026-06-08 20:00, 2026-06-09 02:00, 2026-06-09 08:00, 2026-06-09 14:00, 2026-06-09 20:00, 2026-06-10 20:00, 2026-06-11 20:00, 2026-06-12 08:00, 2026-06-13 02:00, 2026-06-14 08:00, 2026-06-14 14:00, 2026-06-14 20:00, 2026-06-15 14:00, 2026-06-15 20:00, 2026-06-16 02:00, 2026-06-16 14:00, 2026-06-16 20:00, 2026-06-17 20:00, 2026-06-18 20:00, 2026-06-20 02:00, 2026-06-20 14:00, 2026-06-21 14:00, 2026-06-21 20:00, 2026-06-22 08:00, 2026-06-22 14:00, 2026-06-22 20:00, 2026-06-23 08:00, 2026-06-23 14:00, 2026-06-23 20:00, 2026-06-24 14:00, 2026-06-24 20:00, 2026-06-25 20:00, 2026-07-01 02:00, 2026-07-01 14:00, 2026-07-01 20:00, 2026-07-03 20:00, 2026-07-06 08:00, 2026-07-06 14:00, 2026-07-06 20:00, 2026-07-07 14:00, 2026-07-07 20:00, 2026-07-08 14:00, 2026-07-08 20:00, 2026-07-11 14:00, 2026-07-13 20:00, 2026-07-14 02:00, 2026-07-14 08:00, 2026-07-14 14:00, 2026-07-14 20:00, 2026-07-16 08:00, 2026-07-16 20:00, 2026-07-17 02:00, 2026-07-18 14:00, 2026-07-21 14:00, 2026-07-21 20:00, 2026-07-22 02:00, 2026-07-22 20:00, 2026-07-25 08:00, 2026-07-25 14:00, 2026-07-25 20:00, 2026-07-26 14:00, 2026-07-27 20:00, 2026-07-28 14:00, 2026-07-28 20:00, 2026-07-29 02:00, 2026-07-30 20:00, 2026-07-31 08:00, 2026-08-02 20:00, 2026-08-04 14:00, 2026-08-04 20:00, 2026-08-05 20:00, 2026-08-06 14:00, 2026-08-06 20:00, 2026-08-07 02:00, 2026-08-07 08:00, 2026-08-07 14:00, 2026-08-08 20:00, 2026-08-09 20:00, 2026-08-10 14:00, 2026-08-10 20:00, 2026-08-11 20:00, 2026-08-12 08:00, 2026-08-12 14:00, 2026-08-12 20:00, 2026-08-13 02:00, 2026-08-13 08:00, 2026-08-13 14:00, 2026-08-13 20:00, 2026-08-14 02:00, 2026-08-14 08:00, 2026-08-14 14:00, 2026-08-14 20:00, 2026-08-15 02:00, 2026-08-15 08:00, 2026-08-15 14:00, 2026-08-16 20:00, 2026-08-17 20:00, 2026-08-18 02:00, 2026-08-18 08:00, 2026-08-18 14:00, 2026-08-18 20:00, 2026-08-19 02:00, 2026-08-19 08:00, 2026-08-19 14:00, 2026-08-19 20:00, 2026-08-20 08:00, 2026-08-20 14:00, 2026-08-20 20:00, 2026-08-21 02:00, 2026-08-21 08:00, 2026-08-21 20:00, 2026-08-22 14:00, 2026-08-22 20:00, 2026-08-23 02:00, 2026-08-23 14:00, 2026-08-23 20:00, 2026-08-24 20:00, 2026-08-25 08:00, 2026-08-25 14:00, 2026-08-25 20:00, 2026-08-26 08:00, 2026-08-26 20:00, 2026-08-27 02:00, 2026-08-27 08:00, 2026-08-27 14:00, 2026-08-27 20:00, 2026-08-28 08:00, 2026-08-28 14:00, 2026-08-28 20:00, 2026-08-29 02:00, 2026-08-29 14:00, 2026-08-29 20:00, 2026-08-30 14:00, 2026-08-30 20:00, 2026-08-31 20:00, 2026-09-01 08:00, 2026-09-01 20:00, 2026-09-02 08:00, 2026-09-02 14:00, 2026-09-02 20:00
[22:50:06] [SYNC] [INFO] Bucket filter: 335 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 12 matching, 323 differing
[22:50:06] [SYNC] [INFO] RECV WHISPER from Kátorri-Stormrage (SYNC_REQUEST)
[22:50:05] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=sent peer=v0.38.1 remote=13623tx local=15081tx hash=3232344604/1884250325 buckets=335
[22:50:05] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15081, hash: 3232344604)
[22:50:05] [SYNC] [INFO] RECV GUILD from Kátorri-Stormrage (HELLO)
[22:49:52] [SYNC] [INFO] Nudged behind peer Soulcialist to pull (superset, bidirectional hash-gate bypass)
[22:49:52] [SYNC] [INFO] Sent HELLO reply to Soulcialist (tx: 15081, hash: 3232344604)
[22:49:52] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=15081 > remote=13068)
[22:49:52] [SYNC] [INFO] Wire-to-ACK for Soulcialist: 0.27s / 0.52s / 2.13s (min/med/max), timeout 3s
[22:49:52] [SYNC] [INFO] Compression for Soulcialist: 60% / 66% / 70% of raw (min/med/max), 71 chunk(s) over 1 fragment
[22:49:52] [SYNC] [INFO] Retry causes for Soulcialist: ackTimeout=32, nack=0, chunkFail=28.1%, p_frag=16.2% (n=1.9 frags/chunk)
[22:49:52] [SYNC] [INFO] Sync outcomes for Soulcialist: 71 on 1st, 6 on 2nd, 3 on 3rd+, aborted: 1 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[22:49:52] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 3 HELLO replies suppressed, 0 NACKs received
[22:49:52] [SYNC] [INFO] Send complete to Soulcialist - 82/346 chunks, 319 records, 187s
[22:49:52] [SYNC] [ERROR] ACK timeout from Soulcialist after 11 attempts, aborting
[22:49:51] [SYNC] [INFO] Discarded stale ACK for chunk 81 (expected 82)
[22:49:49] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:49] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 11/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:46] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:46] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 10/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:49:44] [SYNC] [INFO] Discarded stale ACK for chunk 81 (expected 82)
[22:49:43] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:43] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 9/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[22:49:40] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:40] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 8/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:37] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:37] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 7/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:34] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:34] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 6/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:34] [SYNC] [INFO] Discarded stale ACK for chunk 81 (expected 82)
[22:49:31] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:31] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 5/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:49:28] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:28] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 4/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:49:27] [SYNC] [INFO] Discarded stale ACK for chunk 81 (expected 82)
[22:49:25] [SYNC] [INFO] Discarded stale ACK for chunk 81 (expected 82)
[22:49:25] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:25] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:22] [SYNC] [INFO] Discarded stale ACK for chunk 81 (expected 82)
[22:49:22] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:22] [SYNC] [WARN] ACK timeout, retrying chunk 82 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:19] [SYNC] [INFO] Chunk 82 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:49:17] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:49:17] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 11/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:14] [SYNC] [INFO] Discarded stale ACK for chunk 80 (expected 81)
[22:49:14] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:49:14] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 10/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:11] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:49:11] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 9/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:49:08] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:49:08] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 8/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:49:05] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:49:05] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 7/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:49:02] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:49:02] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 6/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:48:59] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:48:59] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 5/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:48:57] [SYNC] [INFO] Discarded stale ACK for chunk 80 (expected 81)
[22:48:56] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:48:56] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 4/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:48:54] [SYNC] [INFO] Discarded stale ACK for chunk 80 (expected 81)
[22:48:53] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:48:53] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 3/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:48:52] [SYNC] [INFO] HELLO round Voxle: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=12930tx local=15077tx hash=3232344604/2918505294 buckets=335
[22:48:52] [SYNC] [INFO] RECV GUILD from Voxle (HELLO)
[22:48:50] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:48:50] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[22:48:49] [SYNC] [INFO] Discarded stale ACK for chunk 80 (expected 81)
[22:48:46] [SYNC] [INFO] Chunk 81 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:48:46] [SYNC] [INFO] ACK from Soulcialist for chunk 80/346, 0.9s RTT, wire-to-ACK=0.87s
[22:48:45] [SYNC] [INFO] Chunk 80 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:48:45] [SYNC] [INFO] Sending chunk 80/346 to Soulcialist (1 records, 422->281 bytes, 66% of raw, CTL.avail=3637, CTLq=0/0/0, gap=3.00s)
[22:48:45] [SYNC] [WARN] ACK timeout, retrying chunk 80 (attempt 5/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:48:43] [SYNC] [INFO] Discarded stale ACK for chunk 79 (expected 80)
[22:48:42] [SYNC] [INFO] Chunk 80 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:48:42] [SYNC] [INFO] Sending chunk 80/346 to Soulcialist (1 records, 422->281 bytes, 66% of raw, CTL.avail=3637, CTLq=0/0/0, gap=3.01s)
[22:48:42] [SYNC] [WARN] ACK timeout, retrying chunk 80 (attempt 4/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:48:39] [SYNC] [INFO] Chunk 80 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:48:39] [SYNC] [INFO] Sending chunk 80/346 to Soulcialist (1 records, 422->281 bytes, 66% of raw, CTL.avail=3637, CTLq=0/0/0, gap=3.01s)
[22:48:39] [SYNC] [WARN] ACK timeout, retrying chunk 80 (attempt 3/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:48:38] [SYNC] [INFO] Discarded stale ACK for chunk 79 (expected 80)
[22:48:36] [SYNC] [INFO] Chunk 80 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:48:36] [SYNC] [INFO] Sending chunk 80/346 to Soulcialist (1 records, 422->281 bytes, 66% of raw, CTL.avail=3637, CTLq=0/0/0, gap=3.01s)
[22:48:36] [SYNC] [WARN] ACK timeout, retrying chunk 80 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:48:33] [SYNC] [INFO] Chunk 80 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:48:33] [SYNC] [INFO] Sending chunk 80/346 to Soulcialist (1 records, 422->281 bytes, 66% of raw, CTL.avail=3634, CTLq=0/0/0, gap=1.70s)
[22:48:32] [SYNC] [INFO] Chunk 79 transmitted (0.00s queue-to-wire, CTL.avail=3634)
[22:48:32] [SYNC] [WARN] ACK timeout, retrying chunk 79 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:48:29] [SYNC] [INFO] Discarded stale ACK for chunk 78 (expected 79)
[22:48:29] [SYNC] [INFO] Chunk 79 transmitted (0.00s queue-to-wire, CTL.avail=3634)
[22:48:29] [SYNC] [WARN] ACK timeout, retrying chunk 79 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:48:26] [SYNC] [INFO] Chunk 79 transmitted (0.00s queue-to-wire, CTL.avail=3634)
[22:48:25] [SYNC] [INFO] Chunk 78 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:48:25] [SYNC] [WARN] ACK timeout, retrying chunk 78 (attempt 2/11), fragments~=1, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:48:25] [SYNC] [INFO] Discarded stale ACK for chunk 77 (expected 78)
[22:48:22] [SYNC] [INFO] Chunk 78 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:48:20] [SYNC] [INFO] Chunk 77 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:48:20] [SYNC] [WARN] ACK timeout, retrying chunk 77 (attempt 2/11), fragments~=1, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:48:19] [SYNC] [INFO] Discarded stale ACK for chunk 76 (expected 77)
[22:48:17] [SYNC] [INFO] Chunk 77 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:48:16] [SYNC] [INFO] Chunk 76 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:48:16] [SYNC] [WARN] ACK timeout, retrying chunk 76 (attempt 2/11), fragments~=1, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[22:48:13] [SYNC] [INFO] Chunk 76 transmitted (0.00s queue-to-wire, CTL.avail=3727)
[22:48:12] [SYNC] [INFO] Chunk 75 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:48:10] [SYNC] [INFO] Chunk 74 transmitted (0.00s queue-to-wire, CTL.avail=3728)
[22:48:09] [SYNC] [INFO] Chunk 73 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:48:08] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13623tx local=15073tx hash=991166221/1884250325 buckets=335
[22:48:08] [SYNC] [INFO] RECV GUILD from Kátorri-Stormrage (HELLO)
[22:48:08] [SYNC] [INFO] Chunk 72 transmitted (0.00s queue-to-wire, CTL.avail=3730)
[22:48:07] [SYNC] [INFO] Chunk 71 transmitted (0.00s queue-to-wire, CTL.avail=3653)
[22:48:06] [SYNC] [INFO] ACK from Soulcialist for chunk 70/346, 0.5s RTT, wire-to-ACK=0.47s
[22:48:06] [SYNC] [INFO] Chunk 70 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:48:06] [SYNC] [INFO] Sending chunk 70/346 to Soulcialist (1 records, 425->281 bytes, 66% of raw, CTL.avail=3651, CTLq=0/0/0, gap=1.00s)
[22:48:05] [SYNC] [INFO] Chunk 69 transmitted (0.00s queue-to-wire, CTL.avail=3651)
[22:48:04] [SYNC] [INFO] Chunk 68 transmitted (0.00s queue-to-wire, CTL.avail=3651)
[22:48:03] [SYNC] [INFO] Chunk 67 transmitted (0.00s queue-to-wire, CTL.avail=3657)
[22:48:02] [SYNC] [INFO] Chunk 66 transmitted (0.00s queue-to-wire, CTL.avail=3655)
[22:48:01] [SYNC] [INFO] Chunk 65 transmitted (0.00s queue-to-wire, CTL.avail=3656)
[22:48:00] [SYNC] [INFO] Chunk 64 transmitted (0.00s queue-to-wire, CTL.avail=3655)
[22:47:59] [SYNC] [INFO] Discarded stale ACK for chunk 62 (expected 63)
[22:47:59] [SYNC] [INFO] Chunk 63 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:47:57] [SYNC] [INFO] Chunk 62 transmitted (0.00s queue-to-wire, CTL.avail=3650)
[22:47:57] [SYNC] [WARN] ACK timeout, retrying chunk 62 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:47:54] [SYNC] [INFO] Chunk 62 transmitted (0.00s queue-to-wire, CTL.avail=3650)
[22:47:53] [SYNC] [INFO] Chunk 61 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:47:52] [SYNC] [INFO] ACK from Soulcialist for chunk 60/346, 0.5s RTT, wire-to-ACK=0.53s
[22:47:52] [SYNC] [INFO] Chunk 60 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:47:52] [SYNC] [INFO] Sending chunk 60/346 to Soulcialist (1 records, 416->278 bytes, 66% of raw, CTL.avail=3643, CTLq=0/0/0, gap=1.01s)
[22:47:51] [SYNC] [INFO] Chunk 59 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:50] [SYNC] [INFO] Chunk 58 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:47:49] [SYNC] [INFO] Chunk 57 transmitted (0.00s queue-to-wire, CTL.avail=3723)
[22:47:48] [SYNC] [INFO] Chunk 56 transmitted (0.00s queue-to-wire, CTL.avail=3723)
[22:47:47] [SYNC] [INFO] Chunk 55 transmitted (0.00s queue-to-wire, CTL.avail=3723)
[22:47:46] [SYNC] [INFO] Chunk 54 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:47:45] [SYNC] [INFO] Chunk 53 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:47:44] [SYNC] [INFO] Chunk 52 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:47:43] [SYNC] [INFO] Chunk 51 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:47:42] [SYNC] [INFO] ACK from Soulcialist for chunk 50/346, 0.5s RTT, wire-to-ACK=0.53s
[22:47:42] [SYNC] [INFO] Chunk 50 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:47:42] [SYNC] [INFO] Sending chunk 50/346 to Soulcialist (1 records, 432->279 bytes, 64% of raw, CTL.avail=3639, CTLq=0/0/0, gap=1.00s)
[22:47:41] [SYNC] [INFO] Chunk 49 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:47:40] [SYNC] [INFO] Chunk 48 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:39] [SYNC] [INFO] Chunk 47 transmitted (0.00s queue-to-wire, CTL.avail=3649)
[22:47:38] [SYNC] [INFO] Chunk 46 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:47:37] [SYNC] [INFO] Chunk 45 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:36] [SYNC] [INFO] Chunk 44 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:47:35] [SYNC] [INFO] Discarded stale ACK for chunk 42 (expected 43)
[22:47:35] [SYNC] [INFO] Chunk 43 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:47:34] [SYNC] [INFO] Discarded stale ACK for chunk 41 (expected 42)
[22:47:33] [SYNC] [INFO] Chunk 42 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:47:33] [SYNC] [WARN] ACK timeout, retrying chunk 42 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[22:47:30] [SYNC] [INFO] Chunk 42 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:47:29] [SYNC] [INFO] Chunk 41 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:47:29] [SYNC] [INFO] ACK from Soulcialist for chunk 40/346, 1.4s RTT, wire-to-ACK=1.44s
[22:47:29] [SYNC] [INFO] ACK from Soulcialist for chunk 40/346, 1.4s RTT, wire-to-ACK=1.44s
[22:47:27] [SYNC] [INFO] Chunk 40 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:47:27] [SYNC] [INFO] Sending chunk 40/346 to Soulcialist (1 records, 421->276 bytes, 65% of raw, CTL.avail=3642, CTLq=0/0/0, gap=3.00s)
[22:47:27] [SYNC] [WARN] ACK timeout, retrying chunk 40 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:47:24] [SYNC] [INFO] Chunk 40 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:47:24] [SYNC] [INFO] Sending chunk 40/346 to Soulcialist (1 records, 421->276 bytes, 65% of raw, CTL.avail=3637, CTLq=0/0/0, gap=1.00s)
[22:47:23] [SYNC] [INFO] Chunk 39 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:47:22] [SYNC] [INFO] Chunk 38 transmitted (0.00s queue-to-wire, CTL.avail=3657)
[22:47:21] [SYNC] [INFO] Chunk 37 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:20] [SYNC] [INFO] Chunk 36 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:47:19] [SYNC] [INFO] Chunk 35 transmitted (0.00s queue-to-wire, CTL.avail=3654)
[22:47:18] [SYNC] [INFO] Chunk 34 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:47:17] [SYNC] [INFO] Chunk 33 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:47:16] [SYNC] [INFO] Chunk 32 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:15] [SYNC] [INFO] Chunk 31 transmitted (0.00s queue-to-wire, CTL.avail=3632)
[22:47:15] [SYNC] [INFO] ACK from Soulcialist for chunk 30/346, 0.4s RTT, wire-to-ACK=0.43s
[22:47:14] [SYNC] [INFO] Chunk 30 transmitted (0.00s queue-to-wire, CTL.avail=3631)
[22:47:14] [SYNC] [INFO] Sending chunk 30/346 to Soulcialist (1 records, 428->287 bytes, 67% of raw, CTL.avail=3644, CTLq=0/0/0, gap=1.00s)
[22:47:13] [SYNC] [INFO] Chunk 29 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:47:12] [SYNC] [INFO] Chunk 28 transmitted (0.00s queue-to-wire, CTL.avail=3633)
[22:47:11] [SYNC] [INFO] Chunk 27 transmitted (0.00s queue-to-wire, CTL.avail=3629)
[22:47:10] [SYNC] [INFO] Chunk 26 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:47:09] [SYNC] [INFO] Chunk 25 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:47:08] [SYNC] [INFO] Chunk 24 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:47:07] [SYNC] [INFO] Chunk 23 transmitted (0.00s queue-to-wire, CTL.avail=3650)
[22:47:06] [SYNC] [INFO] Chunk 22 transmitted (0.00s queue-to-wire, CTL.avail=3653)
[22:47:05] [SYNC] [INFO] Chunk 21 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:05] [SYNC] [INFO] ACK from Soulcialist for chunk 20/346, 0.4s RTT, wire-to-ACK=0.43s
[22:47:04] [SYNC] [INFO] Chunk 20 transmitted (0.00s queue-to-wire, CTL.avail=3642)
[22:47:04] [SYNC] [INFO] Sending chunk 20/346 to Soulcialist (1 records, 424->276 bytes, 65% of raw, CTL.avail=3643, CTLq=0/0/0, gap=1.01s)
[22:47:03] [SYNC] [INFO] Chunk 19 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:47:02] [SYNC] [INFO] Chunk 18 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:47:01] [SYNC] [INFO] Chunk 17 transmitted (0.00s queue-to-wire, CTL.avail=3649)
[22:47:00] [SYNC] [INFO] Chunk 16 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:46:59] [SYNC] [INFO] Chunk 15 transmitted (0.00s queue-to-wire, CTL.avail=3634)
[22:46:58] [SYNC] [INFO] Chunk 14 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:46:57] [SYNC] [INFO] Chunk 13 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:46:57] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13623tx local=15071tx hash=527313152/1884250325 buckets=335
[22:46:57] [SYNC] [INFO] RECV GUILD from Katorrí-Stormrage (HELLO)
[22:46:56] [SYNC] [INFO] Chunk 12 transmitted (0.00s queue-to-wire, CTL.avail=3647)
[22:46:55] [SYNC] [INFO] Chunk 11 transmitted (0.00s queue-to-wire, CTL.avail=3632)
[22:46:55] [SYNC] [INFO] ACK from Soulcialist for chunk 10/346, 0.5s RTT, wire-to-ACK=0.47s
[22:46:54] [SYNC] [INFO] Chunk 10 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:46:54] [SYNC] [INFO] Sending chunk 10/346 to Soulcialist (1 records, 419->279 bytes, 66% of raw, CTL.avail=3639, CTLq=0/0/0, gap=1.00s)
[22:46:53] [SYNC] [INFO] Chunk 9 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:46:52] [SYNC] [INFO] Chunk 8 transmitted (0.00s queue-to-wire, CTL.avail=3657)
[22:46:51] [SYNC] [INFO] Chunk 7 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:46:50] [SYNC] [INFO] Chunk 6 transmitted (0.00s queue-to-wire, CTL.avail=3731)
[22:46:49] [SYNC] [INFO] Chunk 5 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:46:48] [SYNC] [INFO] Chunk 4 transmitted (0.00s queue-to-wire, CTL.avail=3657)
[22:46:47] [SYNC] [INFO] Chunk 3 transmitted (0.00s queue-to-wire, CTL.avail=3630)
[22:46:46] [SYNC] [INFO] Chunk 2 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:46:46] [SYNC] [INFO] ACK from Soulcialist for chunk 1/346, 0.4s RTT, wire-to-ACK=0.40s
[22:46:45] [SYNC] [INFO] Chunk 1 transmitted (0.00s queue-to-wire, CTL.avail=3651)
[22:46:45] [SYNC] [INFO] Sending chunk 1/346 to Soulcialist (1 records, 427->267 bytes, 62% of raw, CTL.avail=3627, CTLq=0/0/0)
[22:46:45] [SYNC] [INFO] Sending 319 tx to Soulcialist in 346 chunk(s), capped: 322 bucket(s) deferred
[22:46:45] [SYNC] [INFO] Prep complete for Soulcialist: 15070 examined, 319 selected, 30 tick(s), 0.97s
[22:46:45] [SYNC] [INFO] Send order newest-first: 2026-09-02 20:00 back to 1969-12-31 19:00
[22:46:45] [SYNC] [INFO] Sending 10494 item tx + 4283 money tx from differing days
[22:46:45] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01-16 01:00, 2026-03-06 01:00, 2026-03-11 20:00, 2026-03-20 20:00, 2026-03-24 20:00, 2026-03-25 02:00, 2026-03-26 20:00, 2026-03-27 14:00, 2026-03-28 14:00, 2026-03-28 20:00, 2026-03-29 14:00, 2026-03-30 20:00, 2026-03-31 08:00, 2026-03-31 14:00, 2026-03-31 20:00, 2026-04-02 20:00, 2026-04-04 20:00, 2026-04-05 02:00, 2026-04-05 14:00, 2026-04-05 20:00, 2026-04-06 20:00, 2026-04-07 02:00, 2026-04-07 08:00, 2026-04-07 14:00, 2026-04-07 20:00, 2026-04-08 14:00, 2026-04-08 20:00, 2026-04-09 20:00, 2026-04-10 02:00, 2026-04-10 08:00, 2026-04-10 14:00, 2026-04-10 20:00, 2026-04-11 02:00, 2026-04-11 08:00, 2026-04-11 14:00, 2026-04-11 20:00, 2026-04-12 02:00, 2026-04-12 08:00, 2026-04-12 14:00, 2026-04-12 20:00, 2026-04-13 08:00, 2026-04-13 14:00, 2026-04-13 20:00, 2026-04-14 02:00, 2026-04-14 08:00, 2026-04-14 14:00, 2026-04-14 20:00, 2026-04-15 02:00, 2026-04-15 08:00, 2026-04-15 14:00, 2026-04-15 20:00, 2026-04-16 02:00, 2026-04-16 14:00, 2026-04-16 20:00, 2026-04-17 08:00, 2026-04-17 14:00, 2026-04-17 20:00, 2026-04-18 02:00, 2026-04-18 08:00, 2026-04-18 14:00, 2026-04-18 20:00, 2026-04-19 02:00, 2026-04-19 08:00, 2026-04-19 14:00, 2026-04-19 20:00, 2026-04-20 02:00, 2026-04-20 14:00, 2026-04-20 20:00, 2026-04-21 14:00, 2026-04-21 20:00, 2026-04-22 02:00, 2026-04-22 08:00, 2026-04-22 14:00, 2026-04-22 20:00, 2026-04-23 02:00, 2026-04-23 08:00, 2026-04-23 14:00, 2026-04-23 20:00, 2026-04-24 08:00, 2026-04-24 14:00, 2026-04-24 20:00, 2026-04-25 02:00, 2026-04-25 08:00, 2026-04-25 14:00, 2026-04-25 20:00, 2026-04-26 02:00, 2026-04-26 14:00, 2026-04-26 20:00, 2026-04-27 08:00, 2026-04-27 14:00, 2026-04-27 20:00, 2026-04-28 08:00, 2026-04-28 14:00, 2026-04-28 20:00, 2026-04-29 02:00, 2026-04-29 08:00, 2026-04-29 14:00, 2026-04-29 20:00, 2026-04-30 14:00, 2026-04-30 20:00, 2026-05-01 08:00, 2026-05-01 20:00, 2026-05-02 02:00, 2026-05-02 20:00, 2026-05-03 08:00, 2026-05-03 14:00, 2026-05-03 20:00, 2026-05-04 02:00, 2026-05-04 08:00, 2026-05-04 14:00, 2026-05-04 20:00, 2026-05-05 02:00, 2026-05-05 08:00, 2026-05-05 14:00, 2026-05-05 20:00, 2026-05-06 02:00, 2026-05-06 08:00, 2026-05-06 14:00, 2026-05-06 20:00, 2026-05-07 20:00, 2026-05-08 02:00, 2026-05-08 08:00, 2026-05-08 14:00, 2026-05-08 20:00, 2026-05-09 08:00, 2026-05-09 14:00, 2026-05-09 20:00, 2026-05-10 14:00, 2026-05-10 20:00, 2026-05-11 02:00, 2026-05-11 08:00, 2026-05-11 14:00, 2026-05-11 20:00, 2026-05-12 14:00, 2026-05-12 20:00, 2026-05-13 14:00, 2026-05-13 20:00, 2026-05-14 14:00, 2026-05-14 20:00, 2026-05-15 08:00, 2026-05-15 14:00, 2026-05-16 02:00, 2026-05-17 08:00, 2026-05-17 20:00, 2026-05-18 08:00, 2026-05-18 14:00, 2026-05-18 20:00, 2026-05-19 14:00, 2026-05-19 20:00, 2026-05-20 02:00, 2026-05-20 08:00, 2026-05-20 20:00, 2026-05-21 08:00, 2026-05-21 14:00, 2026-05-21 20:00, 2026-05-22 02:00, 2026-05-22 08:00, 2026-05-22 14:00, 2026-05-22 20:00, 2026-05-23 14:00, 2026-05-24 20:00, 2026-05-25 14:00, 2026-05-26 20:00, 2026-05-27 14:00, 2026-05-27 20:00, 2026-05-28 14:00, 2026-05-30 20:00, 2026-05-31 20:00, 2026-06-01 14:00, 2026-06-01 20:00, 2026-06-02 08:00, 2026-06-02 14:00, 2026-06-02 20:00, 2026-06-04 20:00, 2026-06-05 20:00, 2026-06-06 14:00, 2026-06-06 20:00, 2026-06-07 08:00, 2026-06-07 14:00, 2026-06-07 20:00, 2026-06-08 14:00, 2026-06-08 20:00, 2026-06-09 02:00, 2026-06-09 08:00, 2026-06-09 14:00, 2026-06-09 20:00, 2026-06-10 20:00, 2026-06-11 20:00, 2026-06-12 08:00, 2026-06-13 02:00, 2026-06-14 08:00, 2026-06-14 14:00, 2026-06-14 20:00, 2026-06-15 14:00, 2026-06-15 20:00, 2026-06-16 02:00, 2026-06-16 14:00, 2026-06-16 20:00, 2026-06-17 20:00, 2026-06-18 20:00, 2026-06-20 02:00, 2026-06-20 14:00, 2026-06-21 14:00, 2026-06-21 20:00, 2026-06-22 08:00, 2026-06-22 14:00, 2026-06-22 20:00, 2026-06-23 08:00, 2026-06-23 14:00, 2026-06-23 20:00, 2026-06-24 14:00, 2026-06-24 20:00, 2026-06-25 20:00, 2026-07-01 02:00, 2026-07-01 14:00, 2026-07-01 20:00, 2026-07-03 20:00, 2026-07-06 08:00, 2026-07-06 14:00, 2026-07-06 20:00, 2026-07-07 14:00, 2026-07-07 20:00, 2026-07-08 14:00, 2026-07-08 20:00, 2026-07-11 14:00, 2026-07-13 20:00, 2026-07-14 02:00, 2026-07-14 08:00, 2026-07-14 14:00, 2026-07-14 20:00, 2026-07-16 08:00, 2026-07-16 20:00, 2026-07-17 02:00, 2026-07-18 14:00, 2026-07-21 14:00, 2026-07-21 20:00, 2026-07-22 02:00, 2026-07-22 20:00, 2026-07-25 08:00, 2026-07-25 14:00, 2026-07-25 20:00, 2026-07-26 14:00, 2026-07-27 20:00, 2026-07-28 14:00, 2026-07-28 20:00, 2026-07-29 02:00, 2026-07-30 20:00, 2026-07-31 08:00, 2026-08-02 20:00, 2026-08-04 14:00, 2026-08-04 20:00, 2026-08-05 20:00, 2026-08-06 14:00, 2026-08-06 20:00, 2026-08-07 02:00, 2026-08-07 08:00, 2026-08-07 14:00, 2026-08-08 20:00, 2026-08-09 20:00, 2026-08-10 14:00, 2026-08-10 20:00, 2026-08-11 20:00, 2026-08-12 08:00, 2026-08-12 14:00, 2026-08-12 20:00, 2026-08-13 02:00, 2026-08-13 08:00, 2026-08-13 14:00, 2026-08-13 20:00, 2026-08-14 02:00, 2026-08-14 08:00, 2026-08-14 14:00, 2026-08-14 20:00, 2026-08-15 02:00, 2026-08-15 08:00, 2026-08-15 14:00, 2026-08-16 20:00, 2026-08-17 20:00, 2026-08-18 02:00, 2026-08-18 08:00, 2026-08-18 14:00, 2026-08-18 20:00, 2026-08-19 02:00, 2026-08-19 08:00, 2026-08-19 14:00, 2026-08-19 20:00, 2026-08-20 08:00, 2026-08-20 14:00, 2026-08-20 20:00, 2026-08-21 02:00, 2026-08-21 08:00, 2026-08-21 20:00, 2026-08-22 14:00, 2026-08-22 20:00, 2026-08-23 02:00, 2026-08-23 14:00, 2026-08-23 20:00, 2026-08-24 08:00, 2026-08-24 14:00, 2026-08-24 20:00, 2026-08-25 02:00, 2026-08-25 08:00, 2026-08-25 14:00, 2026-08-25 20:00, 2026-08-26 08:00, 2026-08-26 20:00, 2026-08-27 02:00, 2026-08-27 08:00, 2026-08-27 14:00, 2026-08-27 20:00, 2026-08-28 08:00, 2026-08-28 14:00, 2026-08-28 20:00, 2026-08-29 02:00, 2026-08-29 14:00, 2026-08-29 20:00, 2026-08-30 14:00, 2026-08-30 20:00, 2026-08-31 20:00, 2026-09-01 08:00, 2026-09-01 20:00, 2026-09-02 20:00
[22:46:45] [SYNC] [INFO] Bucket filter: 335 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 11 matching, 324 differing
[22:46:44] [SYNC] [INFO] RECV WHISPER from Soulcialist (SYNC_REQUEST)
[22:46:44] [SYNC] [INFO] Sent HELLO (tx: 15070, hash: 698182465)
[22:46:24] [SYNC] [INFO] HELLO round Soulcialist: verdict=superset-skip reply=sent peer=v0.38.1 remote=13068tx local=15070tx hash=698182465/633549314 buckets=335
[22:46:24] [SYNC] [INFO] Sent HELLO reply to Soulcialist (tx: 15070, hash: 698182465)
[22:46:24] [SYNC] [INFO] RECV GUILD from Soulcialist (HELLO)
[22:46:18] [SYNC] [INFO] Wire-to-ACK for Kátorri-Stormrage: 0.26s / 0.55s / 0.75s (min/med/max), timeout 3s
[22:46:18] [SYNC] [INFO] Compression for Kátorri-Stormrage: 60% / 65% / 70% of raw (min/med/max), 52 chunk(s) over 1 fragment
[22:46:18] [SYNC] [INFO] Retry causes for Kátorri-Stormrage: ackTimeout=9, nack=0, chunkFail=13.8%, p_frag=7.4% (n=1.9 frags/chunk)
[22:46:18] [SYNC] [INFO] Sync outcomes for Kátorri-Stormrage: 46 on 1st, 9 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 1 offline
[22:46:18] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 0 HELLO replies suppressed, 0 NACKs received
[22:46:18] [SYNC] [INFO] Send complete to Kátorri-Stormrage - 56/336 chunks, 307 records, 83s
[22:46:18] [SYNC] [ERROR] Target Kátorri-Stormrage went offline, aborting send
[22:46:18] [SYNC] [INFO] Blocked whisper to offline player: Kátorri-Stormrage
[22:46:17] [SYNC] [INFO] Chunk 55 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:46:17] [SYNC] [WARN] ACK timeout, retrying chunk 55 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:46:14] [SYNC] [INFO] Chunk 55 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:46:13] [SYNC] [INFO] Chunk 54 transmitted (0.00s queue-to-wire, CTL.avail=3724)
[22:46:12] [SYNC] [INFO] Chunk 53 transmitted (0.00s queue-to-wire, CTL.avail=3726)
[22:46:11] [SYNC] [INFO] Chunk 52 transmitted (0.00s queue-to-wire, CTL.avail=3724)
[22:46:10] [SYNC] [INFO] Chunk 51 transmitted (0.00s queue-to-wire, CTL.avail=3724)
[22:46:10] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 50/336, 0.6s RTT, wire-to-ACK=0.63s
[22:46:09] [SYNC] [INFO] Chunk 50 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:46:09] [SYNC] [INFO] Sending chunk 50/336 to Kátorri-Stormrage (1 records, 432->283 bytes, 65% of raw, CTL.avail=3639, CTLq=0/0/0, gap=1.00s)
[22:46:08] [SYNC] [INFO] Chunk 49 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:46:07] [SYNC] [INFO] Chunk 48 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:46:06] [SYNC] [INFO] Chunk 47 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:46:05] [SYNC] [INFO] Chunk 46 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:46:04] [SYNC] [INFO] Chunk 45 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:46:03] [SYNC] [INFO] Chunk 44 transmitted (0.00s queue-to-wire, CTL.avail=3658)
[22:46:02] [SYNC] [INFO] Chunk 43 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:46:01] [SYNC] [INFO] Chunk 42 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:46:00] [SYNC] [INFO] Chunk 41 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:46:00] [SYNC] [WARN] ACK timeout, retrying chunk 41 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:45:57] [SYNC] [INFO] Chunk 41 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:45:57] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 40/336, 0.6s RTT, wire-to-ACK=0.60s
[22:45:56] [SYNC] [INFO] Chunk 40 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:45:56] [SYNC] [INFO] Sending chunk 40/336 to Kátorri-Stormrage (1 records, 435->277 bytes, 63% of raw, CTL.avail=3636, CTLq=0/0/0, gap=1.00s)
[22:45:55] [SYNC] [INFO] Chunk 39 transmitted (0.00s queue-to-wire, CTL.avail=3636)
[22:45:54] [SYNC] [INFO] Chunk 38 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:45:54] [SYNC] [WARN] ACK timeout, retrying chunk 38 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:45:51] [SYNC] [INFO] Chunk 38 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:45:50] [SYNC] [INFO] Chunk 37 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:45:50] [SYNC] [WARN] ACK timeout, retrying chunk 37 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:45:47] [SYNC] [INFO] Chunk 37 transmitted (0.00s queue-to-wire, CTL.avail=3641)
[22:45:46] [SYNC] [INFO] Chunk 36 transmitted (0.00s queue-to-wire, CTL.avail=3644)
[22:45:45] [SYNC] [INFO] Chunk 35 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:45:44] [SYNC] [INFO] Chunk 34 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:45:43] [SYNC] [INFO] Chunk 33 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:45:43] [SYNC] [WARN] ACK timeout, retrying chunk 33 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:45:40] [SYNC] [INFO] Chunk 33 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:45:39] [SYNC] [INFO] Chunk 32 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:45:38] [SYNC] [INFO] Chunk 31 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:45:37] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 30/336, 0.4s RTT, wire-to-ACK=0.40s
[22:45:37] [SYNC] [INFO] Chunk 30 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:45:37] [SYNC] [INFO] Sending chunk 30/336 to Kátorri-Stormrage (1 records, 427->279 bytes, 65% of raw, CTL.avail=3585, CTLq=0/0/0, gap=3.01s)
[22:45:37] [SYNC] [WARN] ACK timeout, retrying chunk 30 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[22:45:34] [SYNC] [INFO] Chunk 30 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:45:34] [SYNC] [INFO] Sending chunk 30/336 to Kátorri-Stormrage (1 records, 427->279 bytes, 65% of raw, CTL.avail=3637, CTLq=0/0/0, gap=1.02s)
[22:45:33] [SYNC] [INFO] Chunk 29 transmitted (0.00s queue-to-wire, CTL.avail=3637)
[22:45:32] [SYNC] [INFO] Chunk 28 transmitted (0.00s queue-to-wire, CTL.avail=3636)
[22:45:31] [SYNC] [INFO] Chunk 27 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:45:31] [SYNC] [WARN] ACK timeout, retrying chunk 27 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:45:28] [SYNC] [INFO] Chunk 27 transmitted (0.00s queue-to-wire, CTL.avail=3639)
[22:45:27] [SYNC] [INFO] Chunk 26 transmitted (0.00s queue-to-wire, CTL.avail=3657)
[22:45:26] [SYNC] [INFO] Chunk 25 transmitted (0.00s queue-to-wire, CTL.avail=3635)
[22:45:25] [SYNC] [INFO] Chunk 24 transmitted (0.00s queue-to-wire, CTL.avail=3643)
[22:45:25] [SORT] [INFO]   demands: 445 total (pinned=0, ext-R=395, ext-L=0, first-empty=50)
[22:45:25] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=14 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=4
[22:45:25] [SORT] [INFO] Sort plan: 7.2ms, 18 ops, 2 deficits, 0 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[22:45:24] [SYNC] [INFO] Chunk 23 transmitted (0.00s queue-to-wire, CTL.avail=3631)
[22:45:24] [SYNC] [WARN] ACK timeout, retrying chunk 23 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:45:21] [SYNC] [INFO] Chunk 23 transmitted (0.00s queue-to-wire, CTL.avail=3631)
[22:45:20] [SYNC] [INFO] Chunk 22 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:45:19] [SYNC] [INFO] Chunk 21 transmitted (0.00s queue-to-wire, CTL.avail=3638)
[22:45:19] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 20/336, 0.6s RTT, wire-to-ACK=0.59s
[22:45:18] [SYNC] [INFO] Chunk 20 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:45:18] [SYNC] [INFO] Sending chunk 20/336 to Kátorri-Stormrage (1 records, 417->273 bytes, 65% of raw, CTL.avail=3646, CTLq=0/0/0, gap=1.02s)
[22:45:18] [SORT] [INFO]   demands: 445 total (pinned=0, ext-R=395, ext-L=0, first-empty=50)
[22:45:18] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=14 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=4
[22:45:18] [SORT] [INFO] Sort plan: 6.1ms, 18 ops, 2 deficits, 0 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[22:45:17] [SYNC] [INFO] Chunk 19 transmitted (0.00s queue-to-wire, CTL.avail=3646)
[22:45:16] [SYNC] [INFO] Chunk 18 transmitted (0.00s queue-to-wire, CTL.avail=3278)
[22:45:15] [SYNC] [INFO] Chunk 17 transmitted (0.00s queue-to-wire, CTL.avail=2835)
[22:45:14] [SYNC] [INFO] Chunk 16 transmitted (0.00s queue-to-wire, CTL.avail=2421)
[22:45:13] [SYNC] [INFO] Chunk 15 transmitted (0.00s queue-to-wire, CTL.avail=1962)
[22:45:13] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 6s)
[22:45:12] [SYNC] [INFO] Chunk 14 transmitted (0.00s queue-to-wire, CTL.avail=1503)
[22:45:12] [SYNC] [INFO] FPS recovered (43) - sync delay restored to 0.1s
[22:45:11] [SYNC] [INFO] Chunk 13 transmitted (0.00s queue-to-wire, CTL.avail=963)
[22:45:10] [SYNC] [INFO] FPS low (17) - sync delay increased to 0.5s
[22:45:10] [SYNC] [INFO] Chunk 12 transmitted (0.00s queue-to-wire, CTL.avail=434)
[22:45:09] [SYNC] [INFO] Chunk 11 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:45:09] [SYNC] [WARN] ACK timeout, retrying chunk 11 (attempt 2/11), fragments~=2, gapSinceWire=3.61s, nacksThisChunk=0, target=online
[22:45:05] [SYNC] [INFO] Chunk 11 transmitted (0.00s queue-to-wire, CTL.avail=3640)
[22:45:05] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 10/336, 0.6s RTT, wire-to-ACK=0.64s
[22:45:04] [SYNC] [INFO] Chunk 10 transmitted (0.00s queue-to-wire, CTL.avail=3645)
[22:45:04] [SYNC] [INFO] Sending chunk 10/336 to Kátorri-Stormrage (1 records, 422->273 bytes, 64% of raw, CTL.avail=3487, CTLq=0/0/0, gap=1.01s)
[22:45:03] [SYNC] [INFO] Chunk 9 transmitted (0.00s queue-to-wire, CTL.avail=3487)
[22:45:02] [SYNC] [INFO] Chunk 8 transmitted (0.00s queue-to-wire, CTL.avail=3017)
[22:45:01] [SYNC] [INFO] Chunk 7 transmitted (0.00s queue-to-wire, CTL.avail=2555)
[22:45:00] [SYNC] [INFO] Chunk 6 transmitted (0.00s queue-to-wire, CTL.avail=2110)
[22:44:59] [SYNC] [INFO] Chunk 5 transmitted (0.00s queue-to-wire, CTL.avail=1665)
[22:44:58] [SYNC] [INFO] Chunk 4 transmitted (0.00s queue-to-wire, CTL.avail=1230)
[22:44:57] [SYNC] [INFO] FPS recovered (32) - sync delay restored to 0.1s
[22:44:57] [SYNC] [INFO] Chunk 3 transmitted (0.00s queue-to-wire, CTL.avail=897)
[22:44:56] [SYNC] [INFO] FPS low (10) - sync delay increased to 0.5s
[22:44:56] [SYNC] [INFO] Chunk 2 transmitted (0.00s queue-to-wire, CTL.avail=442)
[22:44:55] [SYNC] [INFO] ACK from Kátorri-Stormrage for chunk 1/336, 0.5s RTT, wire-to-ACK=0.49s
[22:44:55] [SYNC] [INFO] Chunk 1 transmitted (0.00s queue-to-wire, CTL.avail=441)
[22:44:55] [SYNC] [INFO] Sending chunk 1/336 to Kátorri-Stormrage (1 records, 431->277 bytes, 64% of raw, CTL.avail=869, CTLq=0/0/0)
[22:44:55] [SYNC] [INFO] Sending 307 tx to Kátorri-Stormrage in 336 chunk(s), capped: 319 bucket(s) deferred
[22:44:55] [SYNC] [INFO] Prep complete for Kátorri-Stormrage: 15064 examined, 307 selected, 30 tick(s), 5.38s
[22:44:54] [SYNC] [INFO] Send order newest-first: 2026-09-02 14:00 back to 1969-12-31 19:00
[22:44:54] [SYNC] [INFO] Sending 10443 item tx + 4264 money tx from differing days
[22:44:54] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01-16 01:00, 2026-03-06 01:00, 2026-03-11 20:00, 2026-03-20 20:00, 2026-03-24 20:00, 2026-03-25 02:00, 2026-03-26 20:00, 2026-03-27 14:00, 2026-03-28 14:00, 2026-03-28 20:00, 2026-03-29 14:00, 2026-03-30 20:00, 2026-03-31 08:00, 2026-03-31 14:00, 2026-03-31 20:00, 2026-04-02 20:00, 2026-04-04 20:00, 2026-04-05 02:00, 2026-04-05 14:00, 2026-04-05 20:00, 2026-04-06 20:00, 2026-04-07 02:00, 2026-04-07 08:00, 2026-04-07 14:00, 2026-04-07 20:00, 2026-04-08 14:00, 2026-04-08 20:00, 2026-04-09 20:00, 2026-04-10 02:00, 2026-04-10 08:00, 2026-04-10 14:00, 2026-04-10 20:00, 2026-04-11 02:00, 2026-04-11 08:00, 2026-04-11 14:00, 2026-04-11 20:00, 2026-04-12 02:00, 2026-04-12 08:00, 2026-04-12 14:00, 2026-04-12 20:00, 2026-04-13 08:00, 2026-04-13 14:00, 2026-04-13 20:00, 2026-04-14 02:00, 2026-04-14 08:00, 2026-04-14 14:00, 2026-04-14 20:00, 2026-04-15 02:00, 2026-04-15 08:00, 2026-04-15 14:00, 2026-04-15 20:00, 2026-04-16 02:00, 2026-04-16 14:00, 2026-04-16 20:00, 2026-04-17 08:00, 2026-04-17 14:00, 2026-04-17 20:00, 2026-04-18 02:00, 2026-04-18 08:00, 2026-04-18 14:00, 2026-04-18 20:00, 2026-04-19 02:00, 2026-04-19 08:00, 2026-04-19 14:00, 2026-04-19 20:00, 2026-04-20 02:00, 2026-04-20 14:00, 2026-04-20 20:00, 2026-04-21 14:00, 2026-04-21 20:00, 2026-04-22 02:00, 2026-04-22 08:00, 2026-04-22 14:00, 2026-04-22 20:00, 2026-04-23 02:00, 2026-04-23 08:00, 2026-04-23 14:00, 2026-04-23 20:00, 2026-04-24 08:00, 2026-04-24 14:00, 2026-04-24 20:00, 2026-04-25 02:00, 2026-04-25 08:00, 2026-04-25 14:00, 2026-04-25 20:00, 2026-04-26 02:00, 2026-04-26 14:00, 2026-04-26 20:00, 2026-04-27 08:00, 2026-04-27 14:00, 2026-04-27 20:00, 2026-04-28 08:00, 2026-04-28 14:00, 2026-04-28 20:00, 2026-04-29 02:00, 2026-04-29 08:00, 2026-04-29 14:00, 2026-04-29 20:00, 2026-04-30 14:00, 2026-04-30 20:00, 2026-05-01 08:00, 2026-05-01 20:00, 2026-05-02 02:00, 2026-05-02 20:00, 2026-05-03 08:00, 2026-05-03 14:00, 2026-05-03 20:00, 2026-05-04 02:00, 2026-05-04 08:00, 2026-05-04 14:00, 2026-05-04 20:00, 2026-05-05 02:00, 2026-05-05 08:00, 2026-05-05 14:00, 2026-05-05 20:00, 2026-05-06 02:00, 2026-05-06 08:00, 2026-05-06 14:00, 2026-05-06 20:00, 2026-05-07 20:00, 2026-05-08 02:00, 2026-05-08 08:00, 2026-05-08 14:00, 2026-05-08 20:00, 2026-05-09 08:00, 2026-05-09 14:00, 2026-05-09 20:00, 2026-05-10 14:00, 2026-05-10 20:00, 2026-05-11 02:00, 2026-05-11 08:00, 2026-05-11 14:00, 2026-05-11 20:00, 2026-05-12 14:00, 2026-05-12 20:00, 2026-05-13 14:00, 2026-05-13 20:00, 2026-05-14 14:00, 2026-05-14 20:00, 2026-05-15 08:00, 2026-05-15 14:00, 2026-05-16 02:00, 2026-05-17 08:00, 2026-05-17 20:00, 2026-05-18 08:00, 2026-05-18 14:00, 2026-05-18 20:00, 2026-05-19 14:00, 2026-05-19 20:00, 2026-05-20 02:00, 2026-05-20 08:00, 2026-05-20 20:00, 2026-05-21 08:00, 2026-05-21 14:00, 2026-05-21 20:00, 2026-05-22 02:00, 2026-05-22 08:00, 2026-05-22 14:00, 2026-05-22 20:00, 2026-05-23 14:00, 2026-05-24 20:00, 2026-05-25 14:00, 2026-05-26 20:00, 2026-05-27 14:00, 2026-05-27 20:00, 2026-05-28 14:00, 2026-05-30 20:00, 2026-05-31 20:00, 2026-06-01 14:00, 2026-06-01 20:00, 2026-06-02 08:00, 2026-06-02 14:00, 2026-06-02 20:00, 2026-06-04 20:00, 2026-06-05 20:00, 2026-06-06 14:00, 2026-06-06 20:00, 2026-06-07 08:00, 2026-06-07 14:00, 2026-06-07 20:00, 2026-06-08 14:00, 2026-06-08 20:00, 2026-06-09 02:00, 2026-06-09 08:00, 2026-06-09 14:00, 2026-06-09 20:00, 2026-06-10 20:00, 2026-06-11 20:00, 2026-06-12 08:00, 2026-06-13 02:00, 2026-06-14 08:00, 2026-06-14 14:00, 2026-06-14 20:00, 2026-06-15 14:00, 2026-06-15 20:00, 2026-06-16 02:00, 2026-06-16 14:00, 2026-06-16 20:00, 2026-06-17 20:00, 2026-06-18 20:00, 2026-06-20 02:00, 2026-06-20 14:00, 2026-06-21 14:00, 2026-06-21 20:00, 2026-06-22 08:00, 2026-06-22 14:00, 2026-06-22 20:00, 2026-06-23 08:00, 2026-06-23 14:00, 2026-06-23 20:00, 2026-06-24 14:00, 2026-06-24 20:00, 2026-06-25 20:00, 2026-07-01 02:00, 2026-07-01 14:00, 2026-07-01 20:00, 2026-07-03 20:00, 2026-07-06 08:00, 2026-07-06 14:00, 2026-07-06 20:00, 2026-07-07 14:00, 2026-07-07 20:00, 2026-07-08 14:00, 2026-07-08 20:00, 2026-07-11 14:00, 2026-07-13 20:00, 2026-07-14 02:00, 2026-07-14 08:00, 2026-07-14 14:00, 2026-07-14 20:00, 2026-07-16 08:00, 2026-07-16 20:00, 2026-07-17 02:00, 2026-07-18 14:00, 2026-07-21 14:00, 2026-07-21 20:00, 2026-07-22 02:00, 2026-07-22 20:00, 2026-07-25 08:00, 2026-07-25 14:00, 2026-07-25 20:00, 2026-07-26 14:00, 2026-07-27 20:00, 2026-07-28 14:00, 2026-07-28 20:00, 2026-07-29 02:00, 2026-07-30 20:00, 2026-07-31 08:00, 2026-08-02 20:00, 2026-08-04 14:00, 2026-08-04 20:00, 2026-08-05 20:00, 2026-08-06 14:00, 2026-08-06 20:00, 2026-08-07 02:00, 2026-08-07 08:00, 2026-08-07 14:00, 2026-08-08 20:00, 2026-08-09 20:00, 2026-08-10 14:00, 2026-08-10 20:00, 2026-08-11 20:00, 2026-08-12 08:00, 2026-08-12 14:00, 2026-08-12 20:00, 2026-08-13 02:00, 2026-08-13 08:00, 2026-08-13 14:00, 2026-08-13 20:00, 2026-08-14 02:00, 2026-08-14 08:00, 2026-08-14 14:00, 2026-08-14 20:00, 2026-08-15 02:00, 2026-08-15 08:00, 2026-08-15 14:00, 2026-08-16 20:00, 2026-08-17 20:00, 2026-08-18 02:00, 2026-08-18 08:00, 2026-08-18 14:00, 2026-08-18 20:00, 2026-08-19 02:00, 2026-08-19 08:00, 2026-08-19 14:00, 2026-08-19 20:00, 2026-08-20 08:00, 2026-08-20 14:00, 2026-08-20 20:00, 2026-08-21 02:00, 2026-08-21 08:00, 2026-08-21 20:00, 2026-08-22 14:00, 2026-08-22 20:00, 2026-08-23 02:00, 2026-08-23 14:00, 2026-08-23 20:00, 2026-08-24 20:00, 2026-08-25 08:00, 2026-08-25 14:00, 2026-08-25 20:00, 2026-08-26 08:00, 2026-08-26 20:00, 2026-08-27 02:00, 2026-08-27 08:00, 2026-08-27 14:00, 2026-08-27 20:00, 2026-08-28 08:00, 2026-08-28 14:00, 2026-08-28 20:00, 2026-08-29 02:00, 2026-08-29 14:00, 2026-08-29 20:00, 2026-08-30 14:00, 2026-08-30 20:00, 2026-08-31 20:00, 2026-09-01 08:00, 2026-09-01 20:00, 2026-09-02 14:00
[22:44:54] [SYNC] [INFO] Bucket filter: 335 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 14 matching, 321 differing
[22:44:49] [SYNC] [INFO] RECV WHISPER from Kátorri-Stormrage (SYNC_REQUEST)
[22:44:49] [SYNC] [INFO] Sent HELLO (tx: 15064, hash: 954337631)
```

## Audit-store sessions

The extracts below come from `GuildBankLedgerAuditDB.sessions` in the account SavedVariables, read on 2026-09-03 at 01:07 while the client was running, so the 22:44 login's session is as flushed at 00:45 and not as it ended. The store holds entries oldest first and they are rendered that way here, grouped by channel (sync, then system, then sort), which is the opposite order from the paste above. Per-chunk noise is elided with the counts stated at the end of each sync block (`Chunk N transmitted`, `Sending chunk N/M`, `ACK from` and `RECV` lines); the sort channel is reduced to plan, phase, pass, complete and summary lines, with the elided count stated; each `Differing dates:` line is cut to its first 60 characters with its full length noted. Sessions are numbered by their index in the store on that date. `scripts/audit-sessions.lua` did not exist yet (it shipped with #159 on 2026-09-17); these were produced by a throwaway walker, and the format differs from that script's.

| # | started | build | sync entries (kept window) | sync dropped | sort | system |
|---|---|---|---|---|---|---|
| 1 | 2026-08-26 02:12:31 | 0.38.0 | 4 | 0 | 139 | 5 |
| 2 | 2026-08-26 21:55:45 | 0.38.0 | 1000 (23:27:09 to 23:41:11) | 5683 | 1263 | 23 |
| 3 | 2026-08-26 23:41:29 | 0.38.0 | 122 | 0 | 9 | 2 |
| 4 | 2026-08-27 11:57:14 | 0.39.0 | 1000 (12:18:45 to 12:32:04) | 1397 | 0 | 0 |
| 5 | 2026-08-27 21:40:38 | 0.39.0 | 1000 (22:23:09 to 22:38:47) | 2598 | 545 | 14 |
| 6 | 2026-09-01 20:19:33 | 0.38.1 | 1000 (20:32:01 to 20:44:23) | 959 | 648 | 18 |
| 7 | 2026-09-02 11:01:16 | 0.38.1 | 1000 (11:39:08 to 11:53:40) | 2481 | 0 | 0 |
| 8 | 2026-09-02 12:47:01 | 0.38.1 | 1000 (15:47:22 to 16:53:57) | 10858 | 298 | 15 |
| 9 | 2026-09-02 21:01:20 | 0.38.1 | 1000 (22:17:34 to 22:41:17) | 4808 | 116 | 11 |
| 10 | 2026-09-02 22:44:49 | 0.38.1 | 1000 (00:19:58 to 00:44:45) | 5115 | 6 | 7 |

Sessions 1 to 5 are the 2026-08-26 bags-in-sort test night (v0.38.0) and two sessions on the unstamped v0.39.0 branch the next day; 1 to 3 are already recorded in `docs/sort-logs/2026-08-27-bags-near-full-overflow.md` and the #139 history. They are given at send level only: `Send complete`, `Retry causes`, `Sending N tx`, `Received BUSY`, decode warnings, every non-INFO sync line, and sort completions. Sync lines in this block carry the level only; sort lines are tagged.

### Sessions 1 to 5, send level

```text
===== session #1 start=2026-08-26 02:12:31 v=0.38.0 dropped sync=0
[02:15:08] [SORT] [INFO] Sort: complete in 132.4s - 3 passes, 105 ops issued, 0 remaining, avg 1.26s/op (cursorStuck=0 stalls=0 rescans=7)
===== session #2 start=2026-08-26 21:55:45 v=0.38.0 dropped sync=5683
[23:30:56] [INFO] Send complete to Flamè - 309/309 chunks, 312 records, 311s
[23:30:56] [INFO] Retry causes for Flamè: ackTimeout=0, nack=0, chunkFail=0.0%, p_frag=0.0% (n=1.5 frags/chunk)
[23:30:58] [INFO] Sending 646 tx to Flamè in 665 chunk(s), capped: 282 bucket(s) deferred
[23:31:44] [WARN] Could not decompress a WHISPER message from Katorrí-Stormrage (453 B); likely a lost or corrupt fragment
[23:32:10] [INFO] Received BUSY from Flamè (reason: combat)
[23:32:34] [INFO] Sending 304 tx to Katorrí-Stormrage in 301 chunk(s), capped: 288 bucket(s) deferred
[23:32:39] [WARN] ACK timeout, retrying chunk 3 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:32:48] [WARN] ACK timeout, retrying chunk 9 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[23:32:53] [WARN] ACK timeout, retrying chunk 11 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:33:01] [WARN] ACK timeout, retrying chunk 16 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:33:05] [WARN] ACK timeout, retrying chunk 17 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:33:11] [WARN] ACK timeout, retrying chunk 20 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:33:22] [WARN] ACK timeout, retrying chunk 28 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:33:26] [WARN] ACK timeout, retrying chunk 29 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:33:30] [WARN] ACK timeout, retrying chunk 30 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:33:41] [WARN] ACK timeout, retrying chunk 37 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:33:45] [WARN] ACK timeout, retrying chunk 38 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:33:55] [WARN] ACK timeout, retrying chunk 45 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:34:01] [WARN] ACK timeout, retrying chunk 48 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:35:26] [WARN] ACK timeout, retrying chunk 130 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:35:32] [WARN] ACK timeout, retrying chunk 133 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:35:37] [WARN] ACK timeout, retrying chunk 135 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:35:41] [WARN] ACK timeout, retrying chunk 136 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:35:52] [WARN] ACK timeout, retrying chunk 143 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:35:57] [WARN] ACK timeout, retrying chunk 145 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:36:01] [WARN] ACK timeout, retrying chunk 146 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:36:05] [WARN] ACK timeout, retrying chunk 147 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[23:36:11] [WARN] ACK timeout, retrying chunk 150 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:36:15] [WARN] ACK timeout, retrying chunk 151 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:36:36] [WARN] ACK timeout, retrying chunk 169 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:37:22] [WARN] ACK timeout, retrying chunk 212 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:37:27] [WARN] ACK timeout, retrying chunk 214 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:37:31] [WARN] ACK timeout, retrying chunk 215 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:37:41] [WARN] ACK timeout, retrying chunk 222 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:37:50] [WARN] ACK timeout, retrying chunk 228 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:37:57] [WARN] ACK timeout, retrying chunk 232 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[23:38:02] [WARN] ACK timeout, retrying chunk 234 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[23:38:06] [WARN] ACK timeout, retrying chunk 235 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[23:38:10] [WARN] ACK timeout, retrying chunk 236 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:38:14] [WARN] ACK timeout, retrying chunk 237 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[23:38:18] [WARN] ACK timeout, retrying chunk 238 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:39:22] [INFO] Send complete to Katorrí-Stormrage - 301/301 chunks, 304 records, 408s
[23:39:22] [INFO] Retry causes for Katorrí-Stormrage: ackTimeout=35, nack=0, chunkFail=10.4%, p_frag=7.4% (n=1.4 frags/chunk)
[23:39:44] [WARN] Could not decompress a WHISPER message from Katorrí-Stormrage (454 B); likely a lost or corrupt fragment
[23:39:45] [INFO] Sending 316 tx to Flamè in 314 chunk(s), capped: 281 bucket(s) deferred
[23:40:16] [INFO] Received BUSY from Flamè (reason: combat)
[23:40:35] [INFO] Sending 659 tx to Katorrí-Stormrage in 676 chunk(s), capped: 287 bucket(s) deferred
[23:40:40] [WARN] ACK timeout, retrying chunk 3 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:40:47] [WARN] ACK timeout, retrying chunk 7 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:40:56] [WARN] ACK timeout, retrying chunk 13 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:41:02] [WARN] ACK timeout, retrying chunk 16 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:41:07] [WARN] ACK timeout, retrying chunk 18 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:57:52] [SORT] [INFO] Sort: aborted (bank closed) in 6.8s - 1 passes, 5 ops issued, 227 remaining, avg 1.37s/op (cursorStuck=0 stalls=0 rescans=0)
[22:58:31] [SORT] [INFO] Sort: aborted (cancelled) in 11.3s - 1 passes, 9 ops issued, 223 remaining, avg 1.25s/op (cursorStuck=0 stalls=0 rescans=0)
[23:06:57] [SORT] [INFO] Sort: complete in 443.3s - 4 passes, 401 ops issued, 0 remaining, avg 1.11s/op (cursorStuck=0 stalls=0 rescans=26)
[23:06:57] [SORT] [INFO] Sort bags: 43 deposit(s) issued, 0 skipped
[23:10:46] [SORT] [INFO] Sort: complete in 194.1s - 2 passes, 175 ops issued, 124 remaining, avg 1.11s/op (cursorStuck=0 stalls=0 rescans=11)
[23:15:18] [SORT] [INFO] Sort: complete in 208.1s - 2 passes, 189 ops issued, 68 remaining, avg 1.10s/op (cursorStuck=0 stalls=0 rescans=12)
[23:19:22] [SORT] [INFO] Sort: complete in 224.6s - 3 passes, 197 ops issued, 0 remaining, avg 1.14s/op (cursorStuck=0 stalls=0 rescans=13)
===== session #3 start=2026-08-26 23:41:29 v=0.38.0 dropped sync=0
[23:43:56] [INFO] Sending 606 tx to Flamè in 623 chunk(s), capped: 280 bucket(s) deferred
[23:44:39] [INFO] Received BUSY from Flamè (reason: combat)
[23:45:00] [INFO] Sending 606 tx to Katorrí-Stormrage in 623 chunk(s), capped: 286 bucket(s) deferred
[23:45:05] [WARN] ACK timeout, retrying chunk 3 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:45:09] [WARN] ACK timeout, retrying chunk 4 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[23:45:13] [WARN] ACK timeout, retrying chunk 5 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[23:45:18] [WARN] ACK timeout, retrying chunk 7 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
===== session #4 start=2026-08-27 11:57:14 v=0.39.0 dropped sync=1397
[12:19:18] [WARN] ACK timeout, retrying chunk 231 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[12:19:18] [WARN] Could not decompress a WHISPER message from Raee-Nesingwary (450 B); likely a lost or corrupt fragment
[12:19:20] [INFO] Received BUSY from Raee-Nesingwary (reason: combat)
[12:19:28] [WARN] ACK timeout, retrying chunk 238 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[12:19:35] [WARN] ACK timeout, retrying chunk 242 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:19:53] [WARN] ACK timeout, retrying chunk 257 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:20:09] [WARN] ACK timeout, retrying chunk 270 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:20:16] [WARN] ACK timeout, retrying chunk 274 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[12:22:33] [WARN] ACK timeout, retrying chunk 408 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:23:27] [INFO] Send complete to Druidbruh-Dalaran - 461/461 chunks, 417 records, 521s
[12:23:27] [INFO] Retry causes for Druidbruh-Dalaran: ackTimeout=20, nack=0, chunkFail=4.2%, p_frag=2.8% (n=1.5 frags/chunk)
[12:23:29] [INFO] Sending 599 tx to Druidbruh-Dalaran in 618 chunk(s), capped: 287 bucket(s) deferred
[12:24:57] [WARN] ACK timeout, retrying chunk 86 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:25:02] [WARN] ACK timeout, retrying chunk 88 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:25:14] [WARN] ACK timeout, retrying chunk 97 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:25:24] [WARN] ACK timeout, retrying chunk 104 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[12:25:40] [WARN] ACK timeout, retrying chunk 117 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:25:46] [WARN] ACK timeout, retrying chunk 120 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[12:26:03] [WARN] ACK timeout, retrying chunk 134 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[12:26:49] [WARN] Could not decompress a WHISPER message from Raee-Nesingwary (454 B); likely a lost or corrupt fragment
[12:27:09] [WARN] Could not decompress a WHISPER message from Raee-Nesingwary (454 B); likely a lost or corrupt fragment
[12:31:40] [WARN] ACK timeout, retrying chunk 467 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
===== session #5 start=2026-08-27 21:40:38 v=0.39.0 dropped sync=2598
[22:23:19] [WARN] ACK timeout, retrying chunk 38 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:22] [WARN] ACK timeout, retrying chunk 38 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:25] [WARN] ACK timeout, retrying chunk 38 (attempt 4/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:28] [WARN] ACK timeout, retrying chunk 38 (attempt 5/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:31] [WARN] ACK timeout, retrying chunk 38 (attempt 6/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:23:34] [WARN] ACK timeout, retrying chunk 38 (attempt 7/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:37] [WARN] ACK timeout, retrying chunk 38 (attempt 8/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:40] [WARN] ACK timeout, retrying chunk 38 (attempt 9/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:43] [WARN] ACK timeout, retrying chunk 38 (attempt 10/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:46] [WARN] ACK timeout, retrying chunk 38 (attempt 11/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:23:49] [ERROR] ACK timeout from Vellisara-Nesingwary after 11 attempts, aborting
[22:23:49] [INFO] Send complete to Vellisara-Nesingwary - 38/445 chunks, 426 records, 76s
[22:23:49] [INFO] Retry causes for Vellisara-Nesingwary: ackTimeout=12, nack=0, chunkFail=24.0%, p_frag=12.8% (n=2.0 frags/chunk)
[22:25:06] [WARN] Could not decompress a WHISPER message from Heydk-Spirestone (460 B); likely a lost or corrupt fragment
[22:25:58] [INFO] Sending 482 tx to Heydk-Spirestone in 502 chunk(s), capped: 297 bucket(s) deferred
[22:26:02] [WARN] ACK timeout, retrying chunk 2 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:07] [WARN] ACK timeout, retrying chunk 3 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[22:26:10] [WARN] ACK timeout, retrying chunk 3 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:15] [WARN] ACK timeout, retrying chunk 4 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:18] [WARN] ACK timeout, retrying chunk 4 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:21] [WARN] ACK timeout, retrying chunk 4 (attempt 4/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:34] [WARN] ACK timeout, retrying chunk 14 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:50] [WARN] ACK timeout, retrying chunk 27 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:26:55] [WARN] ACK timeout, retrying chunk 29 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[22:28:38] [WARN] Could not decompress a WHISPER message from Druidbruh-Dalaran (460 B); likely a lost or corrupt fragment
[22:28:52] [WARN] ACK timeout, retrying chunk 142 (attempt 2/11), fragments~=1, gapSinceWire=3.00s, nacksThisChunk=0, target=online
```

### Session 6: 2026-09-01 20:19:33, v0.38.1, sync dropped 959

```text
[20:32:03] [SYNC] [INFO] HELLO round Strikä-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=4444tx local=15005tx hash=3946854976/597650833 buckets=331
[20:32:10] [SYNC] [INFO] HELLO round Voxle: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=12475tx local=15005tx hash=3946854976/2935300282 buckets=331
[20:32:32] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 3946854976)
[20:32:32] [SYNC] [INFO] HELLO round Heydk-Spirestone: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=9454tx local=15005tx hash=3946854976/1596489981 buckets=331
[20:32:32] [SYNC] [INFO] Declined sync from Katorrí-Stormrage (already sending to Flamè)
[20:32:32] [SYNC] [INFO] Sent BUSY to Katorrí-Stormrage
[20:32:33] [SYNC] [INFO] Send complete to Flamè - 299/299 chunks, 300 records, 305s
[20:32:33] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 5 HELLO replies suppressed, 0 NACKs received
[20:32:33] [SYNC] [INFO] Sync outcomes for Flamè: 299 on 1st, 0 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[20:32:33] [SYNC] [INFO] Retry causes for Flamè: ackTimeout=0, nack=0, chunkFail=0.0%, p_frag=0.0% (n=1.1 frags/chunk)
[20:32:33] [SYNC] [INFO] Compression for Flamè: 52% / 69% / 78% of raw (min/med/max), 36 chunk(s) over 1 fragment
[20:32:33] [SYNC] [INFO] Wire-to-ACK for Flamè: 0.20s / 0.48s / 0.60s (min/med/max), timeout 3s
[20:32:33] [SYNC] [INFO] Sent HELLO reply to Flamè (tx: 14842, hash: 3289818235)
[20:32:33] [SYNC] [INFO] HELLO round Flamè: verdict=superset-skip reply=sent peer=v0.38.1 remote=13361tx local=14842tx hash=3289818235/3799320648
[20:32:33] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=14842 > remote=13361)
[20:32:33] [SYNC] [INFO] Sent HELLO reply to Flamè (tx: 14842, hash: 3289818235)
[20:32:33] [SYNC] [INFO] Nudged behind peer Flamè to pull (superset, bidirectional hash-gate bypass)
[20:32:36] [SYNC] [INFO] HELLO round Heydk-Spirestone: verdict=superset-skip reply=n/a peer=v0.38.1 remote=9454tx local=14842tx hash=3289818235/1596489981
[20:32:38] [SYNC] [INFO] Bucket filter: 331 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 6 matching, 325 differing
[20:32:38] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5865 chars)
[20:32:38] [SYNC] [INFO] Sending 10428 item tx + 4203 money tx from differing days
[20:32:38] [SYNC] [INFO] Send order newest-first: 2026-09-01 20:00 back to 1969-12-31 19:00
[20:32:38] [SYNC] [INFO] Prep complete for Heydk-Spirestone: 14842 examined, 511 selected, 30 tick(s), 0.97s
[20:32:38] [SYNC] [INFO] Sending 511 tx to Heydk-Spirestone in 532 chunk(s), capped: 310 bucket(s) deferred
[20:32:50] [SYNC] [WARN] ACK timeout, retrying chunk 10 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[20:32:52] [SYNC] [INFO] Declined sync from Flamè (already sending to Heydk-Spirestone)
[20:32:52] [SYNC] [INFO] Sent BUSY to Flamè
[20:33:09] [SYNC] [INFO] HELLO round Eltherin-Area52: verdict=superset-skip reply=sync-active peer=v0.38.0 remote=1653tx local=14865tx hash=3857773852/1755054023 buckets=331
[20:33:09] [SYNC] [WARN] ACK timeout, retrying chunk 26 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:33:14] [SYNC] [WARN] ACK timeout, retrying chunk 27 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[20:33:36] [SYNC] [INFO] HELLO round Flamè: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13361tx local=14865tx hash=3857773852/3799320648 buckets=331
[20:33:51] [SYNC] [INFO] HELLO round Tyladori-Dalaran: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=4426tx local=14865tx hash=3857773852/1110329804 buckets=331
[20:33:57] [SYNC] [INFO] HELLO round Soulcialist: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=12545tx local=14865tx hash=3857773852/3752161694 buckets=331
[20:34:44] [SYNC] [INFO] HELLO round Strikä-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=4482tx local=14871tx hash=3857773857/2658808545 buckets=331
[20:35:21] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13121tx local=14873tx hash=269704508/3130051113 buckets=331
[20:35:57] [SYNC] [INFO] HELLO round Soulcialist: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=12545tx local=14873tx hash=269704508/3752161694 buckets=331
[20:36:13] [SYNC] [WARN] ACK timeout, retrying chunk 202 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[20:36:20] [SYNC] [WARN] ACK timeout, retrying chunk 206 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:36:51] [SYNC] [WARN] ACK timeout, retrying chunk 234 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[20:37:19] [SYNC] [WARN] ACK timeout, retrying chunk 259 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:37:20] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 14873, hash: 269704508)
[20:37:20] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[20:37:20] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13121tx local=14873tx hash=269704508/3130051113 buckets=331
[20:37:27] [SYNC] [INFO] Sent HELLO (tx: 14873, hash: 269704508)
[20:37:27] [SYNC] [INFO] Declined sync from Flamè (already sending to Heydk-Spirestone)
[20:37:27] [SYNC] [INFO] Sent BUSY to Flamè
[20:37:31] [SYNC] [WARN] ACK timeout, retrying chunk 268 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[20:37:36] [SYNC] [INFO] Sent HELLO reply to Flamè (tx: 14873, hash: 269704508)
[20:37:36] [SYNC] [INFO] Nudged behind peer Flamè to pull (superset, hash-gate bypass)
[20:37:36] [SYNC] [INFO] HELLO round Flamè: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13361tx local=14873tx hash=269704508/3799320648 buckets=331
[20:37:48] [SYNC] [WARN] ACK timeout, retrying chunk 282 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:37:57] [SYNC] [INFO] Sent HELLO reply to Soulcialist (tx: 14873, hash: 269704508)
[20:37:57] [SYNC] [INFO] Nudged behind peer Soulcialist to pull (superset, hash-gate bypass)
[20:37:57] [SYNC] [INFO] HELLO round Soulcialist: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=12545tx local=14873tx hash=269704508/3752161694 buckets=331
[20:37:57] [SYNC] [WARN] ACK timeout, retrying chunk 288 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[20:37:59] [SYNC] [INFO] HELLO round Deemle: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=12606tx local=14873tx hash=269704508/213947776 buckets=331
[20:38:06] [SYNC] [WARN] ACK timeout, retrying chunk 294 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[20:38:28] [SYNC] [WARN] ACK timeout, retrying chunk 312 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[20:38:30] [SYNC] [INFO] Sent HELLO reply to Heydk-Spirestone (tx: 14873, hash: 269704508)
[20:38:30] [SYNC] [INFO] Nudged behind peer Heydk-Spirestone to pull (superset, hash-gate bypass)
[20:38:30] [SYNC] [INFO] HELLO round Heydk-Spirestone: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=9637tx local=14873tx hash=269704508/92590843 buckets=331
[20:38:32] [SYNC] [WARN] ACK timeout, retrying chunk 313 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[20:39:08] [SYNC] [INFO] Sent HELLO reply to Eltherin-Area52 (tx: 14873, hash: 269704508)
[20:39:08] [SYNC] [INFO] Nudged behind peer Eltherin-Area52 to pull (superset, hash-gate bypass)
[20:39:08] [SYNC] [INFO] HELLO round Eltherin-Area52: verdict=superset-nudge reply=hash-suppressed peer=v0.38.0 remote=1666tx local=14873tx hash=269704508/3927710705 buckets=331
[20:39:17] [SYNC] [INFO] Sent HELLO reply to Soulcialist (tx: 14873, hash: 269704508)
[20:39:17] [SYNC] [INFO] Nudged behind peer Soulcialist to pull (superset, hash-gate bypass)
[20:39:17] [SYNC] [INFO] HELLO round Soulcialist: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=12545tx local=14873tx hash=269704508/3752161694 buckets=331
[20:39:36] [SYNC] [INFO] Sent HELLO reply to Flamè (tx: 14873, hash: 269704508)
[20:39:36] [SYNC] [INFO] Nudged behind peer Flamè to pull (superset, hash-gate bypass)
[20:39:36] [SYNC] [INFO] HELLO round Flamè: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13361tx local=14873tx hash=269704508/3799320648 buckets=331
[20:39:36] [SYNC] [INFO] Declined sync from Flamè (already sending to Heydk-Spirestone)
[20:39:36] [SYNC] [INFO] Sent BUSY to Flamè
[20:39:51] [SYNC] [INFO] Sent HELLO reply to Tyladori-Dalaran (tx: 14873, hash: 269704508)
[20:39:51] [SYNC] [INFO] Nudged behind peer Tyladori-Dalaran to pull (superset, hash-gate bypass)
[20:39:51] [SYNC] [INFO] HELLO round Tyladori-Dalaran: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=4411tx local=14873tx hash=269704508/1629335623 buckets=331
[20:39:52] [SYNC] [WARN] ACK timeout, retrying chunk 390 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[20:39:55] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 14873, hash: 269704508)
[20:39:55] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[20:39:55] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13124tx local=14873tx hash=269704508/1577388692 buckets=331
[20:40:20] [SYNC] [WARN] ACK timeout, retrying chunk 415 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[20:40:25] [SYNC] [WARN] ACK timeout, retrying chunk 417 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:40:27] [SYNC] [INFO] Sent HELLO reply to Strikä-Stormrage (tx: 14873, hash: 269704508)
[20:40:27] [SYNC] [INFO] Nudged behind peer Strikä-Stormrage to pull (superset, hash-gate bypass)
[20:40:27] [SYNC] [INFO] HELLO round Strikä-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=4482tx local=14873tx hash=269704508/2658808545 buckets=331
[20:40:30] [SYNC] [WARN] ACK timeout, retrying chunk 419 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:40:49] [SYNC] [INFO] HELLO round Fluffyfistz-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13057tx local=14873tx hash=269704508/51474751 buckets=331
[20:41:19] [SYNC] [WARN] ACK timeout, retrying chunk 464 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[20:41:49] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 14873, hash: 269704508)
[20:41:49] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[20:41:49] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13124tx local=14873tx hash=269704508/1577388692 buckets=331
[20:41:50] [SYNC] [INFO] Declined sync from Katorrí-Stormrage (already sending to Heydk-Spirestone)
[20:41:50] [SYNC] [INFO] Sent BUSY to Katorrí-Stormrage
[20:42:28] [SYNC] [INFO] Send complete to Heydk-Spirestone - 532/532 chunks, 511 records, 590s
[20:42:28] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 9 HELLO replies suppressed, 0 NACKs received
[20:42:28] [SYNC] [INFO] Sync outcomes for Heydk-Spirestone: 514 on 1st, 18 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[20:42:28] [SYNC] [INFO] Retry causes for Heydk-Spirestone: ackTimeout=18, nack=0, chunkFail=3.3%, p_frag=2.3% (n=1.4 frags/chunk)
[20:42:28] [SYNC] [INFO] Compression for Heydk-Spirestone: 51% / 67% / 76% of raw (min/med/max), 213 chunk(s) over 1 fragment
[20:42:28] [SYNC] [INFO] Wire-to-ACK for Heydk-Spirestone: 0.27s / 0.57s / 0.71s (min/med/max), timeout 3s
[20:42:28] [SYNC] [INFO] Sent HELLO reply to Heydk-Spirestone (tx: 14873, hash: 269704508)
[20:42:28] [SYNC] [INFO] Nudged behind peer Heydk-Spirestone to pull (superset, hash-gate bypass)
[20:42:28] [SYNC] [INFO] HELLO round Heydk-Spirestone: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=9708tx local=14873tx hash=269704508/3100303676 buckets=331
[20:42:29] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=14873 > remote=9708)
[20:42:29] [SYNC] [INFO] Bucket filter: 331 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 7 matching, 324 differing
[20:42:29] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5847 chars)
[20:42:30] [SYNC] [INFO] Sending 10442 item tx + 4230 money tx from differing days
[20:42:30] [SYNC] [INFO] Tranche rotation for Heydk-Spirestone: 15 in last tranche, 14 unchanged (demoted), 0 still selected
[20:42:30] [SYNC] [INFO] Send order newest-first: 2026-09-01 20:00 back to 1969-12-31 19:00
[20:42:30] [SYNC] [INFO] Prep complete for Heydk-Spirestone: 14873 examined, 420 selected, 30 tick(s), 1.02s
[20:42:30] [SYNC] [INFO] Sending 420 tx to Heydk-Spirestone in 437 chunk(s), capped: 319 bucket(s) deferred
[20:42:38] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[20:43:09] [SYNC] [INFO] Sent HELLO reply to Eltherin-Area52 (tx: 14873, hash: 269704508)
[20:43:09] [SYNC] [INFO] Nudged behind peer Eltherin-Area52 to pull (superset, hash-gate bypass)
[20:43:09] [SYNC] [INFO] HELLO round Eltherin-Area52: verdict=superset-nudge reply=hash-suppressed peer=v0.38.0 remote=1653tx local=14873tx hash=269704508/1754813628 buckets=331
[20:43:27] [SYNC] [INFO] Sent HELLO (tx: 14873, hash: 269704508)
[20:43:27] [SYNC] [INFO] Declined sync from Flamè (already sending to Heydk-Spirestone)
[20:43:27] [SYNC] [INFO] Sent BUSY to Flamè
[20:43:30] [SYNC] [INFO] Declined sync from Katorrí-Stormrage (already sending to Heydk-Spirestone)
[20:43:30] [SYNC] [INFO] Sent BUSY to Katorrí-Stormrage
[20:43:57] [SYNC] [INFO] Sent HELLO reply to Deemle (tx: 14873, hash: 269704508)
[20:43:57] [SYNC] [INFO] Nudged behind peer Deemle to pull (superset, hash-gate bypass)
[20:43:57] [SYNC] [INFO] HELLO round Deemle: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=12627tx local=14873tx hash=269704508/4012760489 buckets=331
[20:43:57] [SYNC] [INFO] Sent HELLO reply to Soulcialist (tx: 14873, hash: 269704508)
[20:43:57] [SYNC] [INFO] Nudged behind peer Soulcialist to pull (superset, hash-gate bypass)
[20:43:57] [SYNC] [INFO] HELLO round Soulcialist: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=12692tx local=14873tx hash=269704508/1590016676 buckets=331
   (sync: 692 lines starting "Chunk " elided)
   (sync: 39 lines starting "RECV " elided)
   (sync: 73 lines starting "Sending chunk " elided)
   (sync: 71 lines starting "ACK from " elided)
[20:20:57] [SYSTEM] [INFO] Scan: T1=57(event) T2=72(event) T3=66(event) T4=76(event) T5=55(event) T6=93(event) T7=88(event) (507 total, 7s)
[20:22:12] [SYSTEM] [INFO] Post-scan cleanup: removed 16 duplicate record(s)
[20:22:15] [SYSTEM] [INFO] Scan: T1=57(event) T2=72(event) T3=66(event) T4=76(event) T5=55(event) T6=93(event) T7=84(event) (503 total, 5s)
[20:23:25] [SYSTEM] [INFO] Scan: T1=57(event) T2=72(event) T3=66(event) T4=76(event) T5=55(event) T6=93(event) T7=84(event) (503 total, 9s)
[20:27:43] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=92(event) T7=84(event) (606 total, 5s)
[20:30:27] [SYSTEM] [INFO] Scan: T1=59(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=89(event) T7=80(event) (601 total, 5s)
[20:31:01] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=88(event) T7=79(event) (597 total, 5s)
[20:31:14] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=88(event) T7=79(event) (597 total, 5s)
[20:31:19] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=88(event) T7=79(event) (597 total, 5s)
[20:32:33] [SYSTEM] [INFO] Post-scan cleanup: removed 163 duplicate record(s)
[20:32:37] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=88(event) T7=79(event) (597 total, 5s)
[20:32:50] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=90(event) T5=87(event) T6=91(event) T7=79(event) (600 total, 5s)
[20:34:01] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=91(event) T7=79(event) (610 total, 5s)
[20:34:11] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=91(event) T7=79(event) (610 total, 5s)
[20:34:15] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=91(event) T7=79(event) (610 total, 4s)
[20:34:40] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=94(event) T7=76(event) (610 total, 5s)
[20:35:12] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=94(event) T7=76(event) (610 total, 5s)
[20:35:17] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=94(event) T7=76(event) (610 total, 5s)
[20:22:20] [SORT] [INFO] Sort plan: 19.3ms, 249 ops, 5 deficits, 0 unplaced (input: 503 slots / 7 tabs) [T1:57 T2:72 T3:66 T4:76 T5:55 T6:93 T7:84]
[20:22:20] [SORT] [INFO]   phases: P0 merge=1(free=0) P1a assign=130 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=118
[20:22:33] [SORT] [INFO] Sort plan: 19.5ms, 249 ops, 5 deficits, 0 unplaced (input: 503 slots / 7 tabs) [T1:57 T2:72 T3:66 T4:76 T5:55 T6:93 T7:84]
[20:22:33] [SORT] [INFO]   phases: P0 merge=1(free=0) P1a assign=130 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=118
[20:23:00] [SORT] [INFO] Sort plan: 17.8ms, 249 ops, 5 deficits, 0 unplaced (input: 503 slots / 7 tabs) [T1:57 T2:72 T3:66 T4:76 T5:55 T6:93 T7:84]
[20:23:00] [SORT] [INFO]   phases: P0 merge=1(free=0) P1a assign=130 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=118
[20:23:09] [SORT] [INFO] Sort plan: 18.1ms, 249 ops, 5 deficits, 0 unplaced (input: 503 slots / 7 tabs) [T1:57 T2:72 T3:66 T4:76 T5:55 T6:93 T7:84]
[20:23:09] [SORT] [INFO]   phases: P0 merge=1(free=0) P1a assign=130 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=118
[20:27:43] [SORT] [INFO] Sort plan: 9.3ms, 153 ops, 4 deficits, 0 unplaced (input: 606 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:92 T7:84]
[20:27:43] [SORT] [INFO]   phases: P0 merge=41(free=11) P1a assign=3 P1b spill=16(top=12,r=2,l=0,fe=2,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=93
[20:27:43] [SORT] [INFO] Sort: pass 1 left 153 move(s); re-running
[20:30:27] [SORT] [INFO] Sort plan: 6.8ms, 25 ops, 4 deficits, 2 unplaced (input: 601 slots / 7 tabs) [T1:59 T2:98 T3:98 T4:90 T5:87 T6:89 T7:80]
[20:30:27] [SORT] [INFO]   phases: P0 merge=6(free=3) P1a assign=1 P1b spill=9(top=8,r=1,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=11
[20:30:27] [SORT] [INFO] Sort: pass 2 left 25 move(s); re-running
[20:31:01] [SORT] [INFO] Sort plan: 5.9ms, 4 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:31:01] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=2(top=2,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=4
[20:31:01] [SORT] [INFO] Sort: pass 3 left 4 move(s); re-running
[20:31:14] [SORT] [INFO] Sort plan: 6.0ms, 0 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:31:14] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:31:14] [SORT] [INFO] Sort: complete in 475.7s - 4 passes, 431 ops issued, 0 remaining, avg 1.10s/op (cursorStuck=0 stalls=0 rescans=28)
[20:31:14] [SORT] [INFO] Sort hitch summary: 10 hitches, max 4484ms [<=150ms:8 >1000ms:2]
[20:31:14] [SORT] [INFO] Sort: net at finish - ping home 78ms / world 79ms
[20:31:19] [SORT] [INFO] Sort plan: 6.2ms, 0 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:31:19] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:31:23] [SORT] [INFO] Sort plan: 6.4ms, 0 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:31:23] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:32:33] [SORT] [INFO] Sort plan: 6.6ms, 0 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:32:33] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:32:33] [SORT] [INFO] Sort plan: 7.2ms, 0 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:32:33] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:32:40] [SORT] [INFO] Sort plan: 6.4ms, 0 ops, 4 deficits, 2 unplaced (input: 597 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:88 T7:79]
[20:32:40] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:32:51] [SORT] [INFO] Sort plan: 10.4ms, 59 ops, 1 deficits, 2 unplaced (input: 600 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:90 T5:87 T6:91 T7:79]
[20:32:51] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=10 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=3(abort=2) P3 sweep=0 P4 pack=48
[20:34:01] [SORT] [INFO] Sort plan: 8.3ms, 1 ops, 1 deficits, 2 unplaced (input: 610 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:79]
[20:34:01] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=3
[20:34:01] [SORT] [INFO] Sort: pass 1 left 1 move(s); re-running
[20:34:11] [SORT] [INFO] Sort plan: 5.7ms, 0 ops, 1 deficits, 2 unplaced (input: 610 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:79]
[20:34:11] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[20:34:11] [SORT] [INFO] Sort: complete in 77.9s - 2 passes, 60 ops issued, 0 remaining, avg 1.30s/op (cursorStuck=0 stalls=0 rescans=4)
   (sort: 608 lines starting "(sort other)" elided)
```

### Session 7: 2026-09-02 11:01:16, v0.38.1, sync dropped 2481

```text
[11:39:11] [SYNC] [INFO] Sent HELLO (tx: 14860, hash: 3558509031)
[11:39:56] [SYNC] [INFO] HELLO round Warbird-BurningBlade: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=2066tx local=14860tx hash=3558509031/2290392437 buckets=331
[11:40:29] [SYNC] [WARN] ACK timeout, retrying chunk 411 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:40:51] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 14860, hash: 3558509031)
[11:40:51] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[11:40:51] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13472tx local=14860tx hash=3558509031/645420551 buckets=331
[11:41:10] [SYNC] [INFO] Send complete to Katorrí-Stormrage - 451/451 chunks, 422 records, 523s
[11:41:10] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 1 HELLO replies suppressed, 0 NACKs received
[11:41:10] [SYNC] [INFO] Sync outcomes for Katorrí-Stormrage: 427 on 1st, 24 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[11:41:10] [SYNC] [INFO] Retry causes for Katorrí-Stormrage: ackTimeout=24, nack=0, chunkFail=5.1%, p_frag=3.6% (n=1.4 frags/chunk)
[11:41:10] [SYNC] [INFO] Compression for Katorrí-Stormrage: 48% / 65% / 70% of raw (min/med/max), 193 chunk(s) over 1 fragment
[11:41:10] [SYNC] [INFO] Wire-to-ACK for Katorrí-Stormrage: 0.27s / 0.63s / 0.80s (min/med/max), timeout 3s
[11:41:11] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=14860 > remote=13472)
[11:41:11] [SYNC] [INFO] Sent HELLO (tx: 14860, hash: 3558509031)
[11:41:12] [SYNC] [WARN] Could not decompress a WHISPER message from Katorrí-Stormrage (460 B); likely a lost or corrupt fragment
[11:41:32] [SYNC] [INFO] Bucket filter: 331 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 11 matching, 320 differing
[11:41:32] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5775 chars)
[11:41:32] [SYNC] [INFO] Sending 10379 item tx + 4230 money tx from differing days
[11:41:32] [SYNC] [INFO] Tranche rotation for Katorrí-Stormrage: 7 in last tranche, 7 unchanged (demoted), 0 still selected
[11:41:32] [SYNC] [INFO] Send order newest-first: 2026-09-01 20:00 back to 1969-12-31 19:00
[11:41:32] [SYNC] [INFO] Prep complete for Katorrí-Stormrage: 14860 examined, 705 selected, 21 tick(s), 0.67s
[11:41:32] [SYNC] [INFO] Sending 705 tx to Katorrí-Stormrage in 723 chunk(s), capped: 309 bucket(s) deferred
[11:41:35] [SYNC] [WARN] ACK timeout, retrying chunk 1 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:41:45] [SYNC] [WARN] ACK timeout, retrying chunk 8 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:41:50] [SYNC] [WARN] ACK timeout, retrying chunk 10 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:44:52] [SYNC] [WARN] ACK timeout, retrying chunk 188 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:44:56] [SYNC] [WARN] ACK timeout, retrying chunk 189 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:45:05] [SYNC] [WARN] ACK timeout, retrying chunk 195 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:45:10] [SYNC] [WARN] ACK timeout, retrying chunk 197 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:45:14] [SYNC] [WARN] ACK timeout, retrying chunk 198 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:45:21] [SYNC] [WARN] ACK timeout, retrying chunk 202 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:45:33] [SYNC] [WARN] ACK timeout, retrying chunk 211 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:45:46] [SYNC] [WARN] ACK timeout, retrying chunk 221 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:45:54] [SYNC] [INFO] Sent HELLO reply to Warbird-BurningBlade (tx: 14860, hash: 3558509031)
[11:45:54] [SYNC] [INFO] Nudged behind peer Warbird-BurningBlade to pull (superset, hash-gate bypass)
[11:45:54] [SYNC] [INFO] HELLO round Warbird-BurningBlade: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=2119tx local=14860tx hash=3558509031/3541868226 buckets=331
[11:45:55] [SYNC] [WARN] ACK timeout, retrying chunk 227 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:46:07] [SYNC] [WARN] ACK timeout, retrying chunk 236 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:46:14] [SYNC] [WARN] ACK timeout, retrying chunk 240 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[11:46:18] [SYNC] [WARN] ACK timeout, retrying chunk 241 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:46:27] [SYNC] [WARN] ACK timeout, retrying chunk 247 (attempt 2/11), fragments~=2, gapSinceWire=3.04s, nacksThisChunk=0, target=online
[11:46:33] [SYNC] [INFO] HELLO round Warbird-BurningBlade: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=2118tx local=14860tx hash=3558509031/3009102047 buckets=331
[11:46:41] [SYNC] [WARN] ACK timeout, retrying chunk 258 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:46:51] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 14860, hash: 3558509031)
[11:46:51] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[11:46:51] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13466tx local=14860tx hash=3558509031/4247529938 buckets=331
[11:46:52] [SYNC] [WARN] ACK timeout, retrying chunk 266 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:46:55] [SYNC] [WARN] ACK timeout, retrying chunk 266 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:46:59] [SYNC] [WARN] ACK timeout, retrying chunk 267 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:47:11] [SYNC] [INFO] Sent HELLO (tx: 14860, hash: 3558509031)
[11:47:13] [SYNC] [WARN] ACK timeout, retrying chunk 278 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:19] [SYNC] [WARN] ACK timeout, retrying chunk 281 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[11:47:25] [SYNC] [WARN] ACK timeout, retrying chunk 284 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:34] [SYNC] [WARN] ACK timeout, retrying chunk 290 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:41] [SYNC] [WARN] ACK timeout, retrying chunk 294 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:45] [SYNC] [WARN] ACK timeout, retrying chunk 295 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:49] [SYNC] [WARN] ACK timeout, retrying chunk 296 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:52] [SYNC] [WARN] ACK timeout, retrying chunk 296 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:55] [SYNC] [WARN] ACK timeout, retrying chunk 296 (attempt 4/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:47:58] [SYNC] [WARN] ACK timeout, retrying chunk 296 (attempt 5/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:48:00] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 14860, hash: 3558509031)
[11:48:00] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[11:48:00] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13462tx local=14860tx hash=3558509031/1722553440 buckets=331
[11:48:02] [SYNC] [INFO] Discarded stale ACK for chunk 297 (expected 298)
[11:48:22] [SYNC] [WARN] ACK timeout, retrying chunk 315 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:48:37] [SYNC] [WARN] ACK timeout, retrying chunk 327 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[11:48:42] [SYNC] [WARN] ACK timeout, retrying chunk 329 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:48:56] [SYNC] [WARN] ACK timeout, retrying chunk 339 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:49:05] [SYNC] [WARN] ACK timeout, retrying chunk 343 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:49:19] [SYNC] [WARN] ACK timeout, retrying chunk 354 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:49:25] [SYNC] [WARN] ACK timeout, retrying chunk 357 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:49:28] [SYNC] [WARN] ACK timeout, retrying chunk 357 (attempt 3/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:50:43] [SYNC] [WARN] ACK timeout, retrying chunk 429 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[11:50:47] [SYNC] [WARN] ACK timeout, retrying chunk 430 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:50:58] [SYNC] [WARN] ACK timeout, retrying chunk 438 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[11:51:03] [SYNC] [WARN] ACK timeout, retrying chunk 440 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:51:54] [SYNC] [INFO] Sent HELLO reply to Warbird-BurningBlade (tx: 14860, hash: 3558509031)
[11:51:54] [SYNC] [INFO] Nudged behind peer Warbird-BurningBlade to pull (superset, hash-gate bypass)
[11:51:54] [SYNC] [INFO] HELLO round Warbird-BurningBlade: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=2118tx local=14860tx hash=3558509031/3009104926 buckets=331
[11:52:31] [SYNC] [WARN] ACK timeout, retrying chunk 524 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[11:53:11] [SYNC] [INFO] Sent HELLO (tx: 14860, hash: 3558509031)
[11:53:12] [SYNC] [INFO] Declined sync from Warbird-BurningBlade (already sending to Katorrí-Stormrage)
[11:53:12] [SYNC] [INFO] Sent BUSY to Warbird-BurningBlade
   (sync: 756 lines starting "Chunk " elided)
   (sync: 9 lines starting "RECV " elided)
   (sync: 79 lines starting "Sending chunk " elided)
   (sync: 73 lines starting "ACK from " elided)
```

### Session 8: 2026-09-02 12:47:01, v0.38.1, sync dropped 10858

```text
[15:47:26] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15005, hash: 607833142)
[15:47:26] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[15:47:26] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13567tx local=15005tx hash=607833142/3285947948 buckets=334
[15:48:12] [SYNC] [INFO] Discarded stale ACK for chunk 298 (expected 299)
[15:48:15] [SYNC] [WARN] ACK timeout, retrying chunk 299 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[15:48:17] [SYNC] [INFO] Discarded stale ACK for chunk 299 (expected 300)
[15:48:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[15:48:59] [SYNC] [WARN] Could not decompress a WHISPER message from Aeglos-ArgentDawn (456 B); likely a lost or corrupt fragment
[15:49:19] [SYNC] [INFO] Declined sync from Aeglos-ArgentDawn (already sending to Flameus)
[15:49:19] [SYNC] [INFO] Sent BUSY to Aeglos-ArgentDawn
[15:49:23] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 15005, hash: 607833142)
[15:49:23] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[15:49:23] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13567tx local=15005tx hash=607833142/3285947948 buckets=334
[15:49:27] [SYNC] [INFO] Declined sync from Katorrí-Stormrage (already sending to Flameus)
[15:49:27] [SYNC] [INFO] Sent BUSY to Katorrí-Stormrage
[15:49:49] [SYNC] [INFO] Loading screen detected - sync paused
[15:49:50] [SYNC] [INFO] SendNextChunk deferred - zone/combat transition in progress
[15:50:00] [SYNC] [INFO] Zone cooldown complete - sync resumed
[15:50:00] [SYNC] [INFO] CTL low (avail=?, need=400, #1, t=170206.096) - deferring 1s
[15:50:01] [SYNC] [INFO] CTL low (avail=?, need=400, #2, t=170207.103) - deferring 1s
[15:50:02] [SYNC] [INFO] CTL low (avail=?, need=400, #3, t=170208.105) - deferring 1s
[15:50:03] [SYNC] [INFO] CTL low (avail=?, need=400, #4, t=170209.111) - deferring 1s
[15:50:04] [SYNC] [INFO] CTL low (avail=?, need=400, #5, t=170210.115) - deferring 1s
[15:50:05] [SYNC] [INFO] CTL low (avail=?, need=400, #6, t=170211.116) - deferring 1s
[15:50:06] [SYNC] [INFO] CTL low (avail=?, need=400, #7, t=170212.117) - deferring 1s
[15:50:07] [SYNC] [INFO] CTL low (avail=?, need=400, #8, t=170213.123) - deferring 1s
[15:50:08] [SYNC] [INFO] Loading screen detected - sync paused
[15:50:08] [SYNC] [INFO] SendNextChunk deferred - zone/combat transition in progress
[15:50:10] [SYNC] [INFO] NACK from Flameus for chunk 391 - re-transmitting, CTL.avail=-602
[15:50:12] [SYNC] [INFO] SendNextChunk deferred - zone/combat transition in progress
[15:50:15] [SYNC] [INFO] Zone cooldown complete - sync resumed
[15:50:15] [SYNC] [INFO] CTL low (avail=0, need=400, #9, t=170221.038) - deferring 1s
[15:50:16] [SYNC] [INFO] CTL low (avail=0, need=400, #10, t=170222.038) - deferring 1s
[15:50:19] [SYNC] [INFO] CTL recovered: 12 deferrals, 0 overlapped, stall 19.0s, min avail 0, recovery 978 B/s (zone/combat pause overlapped; stall includes dead time)
[15:50:33] [SYNC] [INFO] Sent HELLO reply to Warbird-BurningBlade (tx: 15005, hash: 607833142)
[15:50:33] [SYNC] [INFO] Nudged behind peer Warbird-BurningBlade to pull (superset, hash-gate bypass)
[15:50:33] [SYNC] [INFO] HELLO round Warbird-BurningBlade: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=2233tx local=15005tx hash=607833142/1948026008 buckets=334
[15:50:45] [SYNC] [INFO] Loading screen detected - sync paused
[15:50:45] [SYNC] [INFO] SendNextChunk deferred - zone/combat transition in progress
[15:50:52] [SYNC] [INFO] Zone cooldown complete - sync resumed
[15:50:55] [SYNC] [WARN] ACK timeout, retrying chunk 417 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[15:50:58] [SYNC] [WARN] ACK timeout, retrying chunk 417 (attempt 3/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[15:51:01] [SYNC] [WARN] ACK timeout, retrying chunk 417 (attempt 4/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[15:51:04] [SYNC] [WARN] ACK timeout, retrying chunk 417 (attempt 5/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[15:51:07] [SYNC] [WARN] ACK timeout, retrying chunk 417 (attempt 6/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[15:51:09] [SYNC] [INFO] Combat started - aborting sync
[15:51:09] [SYNC] [INFO] Send complete to Flameus - 417/487 chunks, 466 records, 490s
[15:51:09] [SYNC] [INFO] Sync stats: 12 CTL deferrals, 0 overlapped timers, longest stall 19.0s, 1 HELLO replies suppressed, 1 NACKs received
[15:51:09] [SYNC] [INFO] Sync outcomes for Flameus: 405 on 1st, 2 on 2nd, 1 on 3rd+, aborted: 0 ackTimeout + 1 combat + 0 zone + 0 busy + 0 offline
[15:51:09] [SYNC] [INFO] Retry causes for Flameus: ackTimeout=10, nack=0, chunkFail=2.4%, p_frag=1.5% (n=1.6 frags/chunk)
[15:51:09] [SYNC] [INFO] Compression for Flameus: 48% / 66% / 70% of raw (min/med/max), 239 chunk(s) over 1 fragment
[15:51:09] [SYNC] [INFO] Wire-to-ACK for Flameus: 0.10s / 0.56s / 2.98s (min/med/max), timeout 3s
[15:51:09] [SYNC] [INFO] Sent BUSY to send target: Flameus
[15:51:22] [SYNC] [INFO] Combat cooldown complete - sync resumed
[15:51:22] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[15:52:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[15:54:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[15:56:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[15:58:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:00:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:02:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:04:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:06:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:08:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:10:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:10:59] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-skip reply=n/a peer=v0.38.1 remote=13567tx local=15005tx hash=607833142/3285947948 buckets=334
[16:10:59] [SYNC] [INFO] Declined sync from Katorrí-Stormrage (in combat) - sent BUSY
[16:11:01] [SYNC] [INFO] Sent HELLO reply to Flameus (tx: 15005, hash: 607833142)
[16:11:01] [SYNC] [INFO] Nudged behind peer Flameus to pull (superset, hash-gate bypass)
[16:11:01] [SYNC] [INFO] HELLO round Flameus: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13749tx local=15005tx hash=607833142/3582769210 buckets=334
[16:11:01] [SYNC] [INFO] Sent HELLO reply to Aeglos-ArgentDawn (tx: 15005, hash: 607833142)
[16:11:01] [SYNC] [INFO] Nudged behind peer Aeglos-ArgentDawn to pull (superset, hash-gate bypass)
[16:11:01] [SYNC] [INFO] HELLO round Aeglos-ArgentDawn: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=12804tx local=15005tx hash=607833142/391361367 buckets=334
[16:11:02] [SYNC] [INFO] Bucket filter: 334 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 20 matching, 314 differing
[16:11:02] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5667 chars)
[16:11:02] [SYNC] [INFO] Sending 10451 item tx + 4218 money tx from differing days
[16:11:02] [SYNC] [INFO] Tranche rotation for Flameus: 9 in last tranche, 9 unchanged (demoted), 0 still selected
[16:11:02] [SYNC] [INFO] Send order newest-first: 2026-09-01 20:00 back to 1969-12-31 19:00
[16:11:02] [SYNC] [INFO] Prep complete for Flameus: 15005 examined, 300 selected, 20 tick(s), 0.34s
[16:11:02] [SYNC] [INFO] Sending 300 tx to Flameus in 325 chunk(s), capped: 309 bucket(s) deferred
[16:11:07] [SYNC] [WARN] ACK timeout, retrying chunk 3 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[16:11:12] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:11:15] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 3/11), fragments~=2, gapSinceWire=3.05s, nacksThisChunk=0, target=online
[16:11:18] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 4/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:11:19] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 15005, hash: 607833142)
[16:11:19] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[16:11:19] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13567tx local=15005tx hash=607833142/3285947948 buckets=334
[16:11:21] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 5/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:11:24] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 6/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:11:28] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 7/11), fragments~=2, gapSinceWire=3.06s, nacksThisChunk=0, target=online
[16:11:31] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 8/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:11:34] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 9/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:11:37] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 10/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:11:39] [SYNC] [INFO] Discarded stale ACK for chunk 4 (expected 5)
[16:11:40] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 11/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:11:43] [SYNC] [ERROR] ACK timeout from Flameus after 11 attempts, aborting
[16:11:43] [SYNC] [INFO] Send complete to Flameus - 5/325 chunks, 300 records, 41s
[16:11:43] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 0 HELLO replies suppressed, 0 NACKs received
[16:11:43] [SYNC] [INFO] Sync outcomes for Flameus: 2 on 1st, 1 on 2nd, 0 on 3rd+, aborted: 1 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[16:11:43] [SYNC] [INFO] Retry causes for Flameus: ackTimeout=11, nack=0, chunkFail=50.0%, p_frag=29.3% (n=2.0 frags/chunk)
[16:11:43] [SYNC] [INFO] Compression for Flameus: 64% / 65% / 66% of raw (min/med/max), 5 chunk(s) over 1 fragment
[16:11:43] [SYNC] [INFO] Wire-to-ACK for Flameus: 0.62s / 0.96s / 1.17s (min/med/max), timeout 3s
[16:11:43] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=15005 > remote=13749)
[16:12:58] [SYNC] [INFO] Sent HELLO (tx: 15005, hash: 607833142)
[16:12:59] [SYNC] [INFO] Bucket filter: 334 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 13 matching, 321 differing
[16:12:59] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5793 chars)
[16:12:59] [SYNC] [INFO] Sending 10437 item tx + 4249 money tx from differing days
[16:12:59] [SYNC] [INFO] Tranche rotation for Katorrí-Stormrage: 2 in last tranche, 1 unchanged (demoted), 0 still selected
[16:12:59] [SYNC] [INFO] Send order newest-first: 2026-09-02 14:00 back to 1969-12-31 19:00
[16:13:00] [SYNC] [INFO] Prep complete for Katorrí-Stormrage: 15005 examined, 305 selected, 20 tick(s), 0.68s
[16:13:00] [SYNC] [INFO] Sending 305 tx to Katorrí-Stormrage in 329 chunk(s), capped: 309 bucket(s) deferred
[16:13:09] [SYNC] [WARN] ACK timeout, retrying chunk 7 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[16:13:19] [SYNC] [WARN] ACK timeout, retrying chunk 14 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:13:31] [SYNC] [WARN] ACK timeout, retrying chunk 23 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:13:35] [SYNC] [WARN] ACK timeout, retrying chunk 24 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[16:13:40] [SYNC] [WARN] ACK timeout, retrying chunk 26 (attempt 2/11), fragments~=2, gapSinceWire=3.03s, nacksThisChunk=0, target=online
[16:13:45] [SYNC] [WARN] ACK timeout, retrying chunk 28 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:13:56] [SYNC] [WARN] ACK timeout, retrying chunk 36 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:14:05] [SYNC] [WARN] ACK timeout, retrying chunk 42 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:14:08] [SYNC] [INFO] Sent HELLO reply to Warbird-BurningBlade (tx: 15005, hash: 607833142)
[16:14:08] [SYNC] [INFO] Nudged behind peer Warbird-BurningBlade to pull (superset, hash-gate bypass)
[16:14:08] [SYNC] [INFO] HELLO round Warbird-BurningBlade: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=2251tx local=15005tx hash=607833142/80884208 buckets=334
[16:14:10] [SYNC] [WARN] ACK timeout, retrying chunk 44 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:14:17] [SYNC] [WARN] ACK timeout, retrying chunk 48 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:14:25] [SYNC] [WARN] ACK timeout, retrying chunk 53 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:14:32] [SYNC] [WARN] ACK timeout, retrying chunk 57 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:14:42] [SYNC] [WARN] ACK timeout, retrying chunk 64 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:15:06] [SYNC] [WARN] ACK timeout, retrying chunk 84 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:15:19] [SYNC] [WARN] ACK timeout, retrying chunk 94 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:15:31] [SYNC] [WARN] ACK timeout, retrying chunk 103 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:15:53] [SYNC] [WARN] ACK timeout, retrying chunk 122 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:15:59] [SYNC] [WARN] ACK timeout, retrying chunk 125 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:16:05] [SYNC] [WARN] ACK timeout, retrying chunk 128 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:16:14] [SYNC] [INFO] HELLO round Aeglos-ArgentDawn: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=12812tx local=15006tx hash=328011141/164193929 buckets=334
[16:16:17] [SYNC] [WARN] ACK timeout, retrying chunk 137 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:16:50] [SYNC] [INFO] HELLO round Flameus: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13749tx local=15006tx hash=328011141/3582769210 buckets=334
[16:17:19] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13581tx local=15006tx hash=328011141/2888704798 buckets=334
[16:17:32] [SYNC] [WARN] ACK timeout, retrying chunk 208 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:17:40] [SYNC] [INFO] Loading screen detected - sync paused
[16:17:40] [SYNC] [INFO] SendNextChunk deferred - zone/combat transition in progress
[16:17:42] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:17:50] [SYNC] [INFO] Zone cooldown complete - sync resumed
[16:17:50] [SYNC] [INFO] CTL low (avail=?, need=400, #1, t=171876.364) - deferring 1s
[16:17:51] [SYNC] [INFO] CTL low (avail=?, need=400, #2, t=171877.370) - deferring 1s
[16:17:52] [SYNC] [INFO] CTL low (avail=?, need=400, #3, t=171878.377) - deferring 1s
[16:17:53] [SYNC] [INFO] CTL low (avail=?, need=400, #4, t=171879.383) - deferring 1s
[16:17:54] [SYNC] [INFO] CTL low (avail=?, need=400, #5, t=171880.390) - deferring 1s
[16:17:55] [SYNC] [INFO] CTL low (avail=?, need=400, #6, t=171881.398) - deferring 1s
[16:17:56] [SYNC] [INFO] CTL low (avail=?, need=400, #7, t=171882.403) - deferring 1s
[16:17:57] [SYNC] [INFO] CTL recovered: 7 deferrals, 0 overlapped, stall 7.0s, min avail ?, recovery ? B/s
[16:18:03] [SYNC] [WARN] ACK timeout, retrying chunk 219 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:18:10] [SYNC] [WARN] ACK timeout, retrying chunk 222 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:18:16] [SYNC] [WARN] ACK timeout, retrying chunk 225 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[16:18:20] [SYNC] [WARN] ACK timeout, retrying chunk 226 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:18:29] [SYNC] [WARN] ACK timeout, retrying chunk 232 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:18:33] [SYNC] [WARN] ACK timeout, retrying chunk 233 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:18:50] [SYNC] [INFO] Sent HELLO reply to Flameus (tx: 15006, hash: 328011141)
[16:18:50] [SYNC] [INFO] Nudged behind peer Flameus to pull (superset, hash-gate bypass)
[16:18:50] [SYNC] [INFO] HELLO round Flameus: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13749tx local=15006tx hash=328011141/3582769210 buckets=334
[16:18:50] [SYNC] [INFO] Declined sync from Flameus (already sending to Katorrí-Stormrage)
[16:18:50] [SYNC] [INFO] Sent BUSY to Flameus
[16:19:21] [SYNC] [WARN] ACK timeout, retrying chunk 278 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:20:09] [SYNC] [WARN] ACK timeout, retrying chunk 323 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:20:14] [SYNC] [WARN] ACK timeout, retrying chunk 325 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:20:21] [SYNC] [WARN] ACK timeout, retrying chunk 329 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:20:22] [SYNC] [INFO] Send complete to Katorrí-Stormrage - 329/329 chunks, 305 records, 442s
[16:20:22] [SYNC] [INFO] Sync stats: 7 CTL deferrals, 0 overlapped timers, longest stall 7.0s, 3 HELLO replies suppressed, 0 NACKs received
[16:20:22] [SYNC] [INFO] Sync outcomes for Katorrí-Stormrage: 298 on 1st, 31 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[16:20:22] [SYNC] [INFO] Retry causes for Katorrí-Stormrage: ackTimeout=31, nack=0, chunkFail=8.6%, p_frag=5.8% (n=1.5 frags/chunk)
[16:20:22] [SYNC] [INFO] Compression for Katorrí-Stormrage: 51% / 66% / 71% of raw (min/med/max), 168 chunk(s) over 1 fragment
[16:20:22] [SYNC] [INFO] Wire-to-ACK for Katorrí-Stormrage: 0.30s / 0.63s / 0.83s (min/med/max), timeout 3s
[16:20:22] [SYNC] [INFO] Sent HELLO reply to Katorrí-Stormrage (tx: 15006, hash: 328011141)
[16:20:22] [SYNC] [INFO] Nudged behind peer Katorrí-Stormrage to pull (superset, hash-gate bypass)
[16:20:22] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13578tx local=15006tx hash=328011141/709817471 buckets=334
[16:20:23] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=15006 > remote=13578)
[16:20:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:20:59] [SYNC] [INFO] Bucket filter: 334 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 19 matching, 315 differing
[16:20:59] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5685 chars)
[16:20:59] [SYNC] [INFO] Sending 10455 item tx + 4226 money tx from differing days
[16:20:59] [SYNC] [INFO] Tranche rotation for Flameus: 5 in last tranche, 5 unchanged (demoted), 0 still selected
[16:20:59] [SYNC] [INFO] Send order newest-first: 2026-09-02 14:00 back to 1969-12-31 19:00
[16:20:59] [SYNC] [INFO] Prep complete for Flameus: 15006 examined, 467 selected, 30 tick(s), 0.48s
[16:20:59] [SYNC] [INFO] Sending 467 tx to Flameus in 490 chunk(s), capped: 306 bucket(s) deferred
[16:21:05] [SYNC] [WARN] ACK timeout, retrying chunk 4 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:21:11] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:21:14] [SYNC] [WARN] ACK timeout, retrying chunk 5 (attempt 3/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:21:16] [SYNC] [INFO] Loading screen detected - sync paused
[16:21:17] [SYNC] [INFO] Discarded stale ACK for chunk 4 (expected 5)
[16:21:23] [SYNC] [INFO] Zone cooldown complete - sync resumed
[16:21:26] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 4/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:21:29] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 5/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:21:32] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 6/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:21:35] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 7/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[16:21:38] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 8/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:21:41] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 9/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:21:44] [SYNC] [WARN] ACK timeout, retrying chunk 6 (attempt 10/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[16:21:45] [SYNC] [INFO] Combat started - aborting sync
[16:21:45] [SYNC] [INFO] Send complete to Flameus - 6/490 chunks, 467 records, 46s
[16:21:45] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 0 HELLO replies suppressed, 0 NACKs received
[16:21:45] [SYNC] [INFO] Sync outcomes for Flameus: 3 on 1st, 1 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 1 combat + 1 zone + 0 busy + 0 offline
[16:21:45] [SYNC] [INFO] Retry causes for Flameus: ackTimeout=10, nack=0, chunkFail=50.0%, p_frag=29.3% (n=2.0 frags/chunk)
[16:21:45] [SYNC] [INFO] Compression for Flameus: 61% / 65% / 67% of raw (min/med/max), 6 chunk(s) over 1 fragment
[16:21:45] [SYNC] [INFO] Wire-to-ACK for Flameus: 0.53s / 0.57s / 2.86s (min/med/max), timeout 3s
[16:21:45] [SYNC] [INFO] Sent BUSY to send target: Flameus
[16:22:54] [SYNC] [INFO] Combat cooldown complete - sync resumed
[16:22:54] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:24:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:26:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:28:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:30:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:32:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:34:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:36:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:38:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:40:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:42:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:44:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:46:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:48:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:50:58] [SYNC] [INFO] Sent HELLO (tx: 15006, hash: 328011141)
[16:52:50] [SYNC] [INFO] Sent HELLO reply to Flameus (tx: 15006, hash: 328011141)
[16:52:50] [SYNC] [INFO] Nudged behind peer Flameus to pull (superset, hash-gate bypass)
[16:52:50] [SYNC] [INFO] HELLO round Flameus: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13749tx local=15006tx hash=328011141/3582769210 buckets=334
[16:52:50] [SYNC] [INFO] Bucket filter: 334 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 19 matching, 315 differing
[16:52:50] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5685 chars)
[16:52:51] [SYNC] [INFO] Sending 10455 item tx + 4226 money tx from differing days
[16:52:51] [SYNC] [INFO] Tranche rotation for Flameus: 9 in last tranche, 9 unchanged (demoted), 0 still selected
[16:52:51] [SYNC] [INFO] Send order newest-first: 2026-09-02 14:00 back to 1969-12-31 19:00
[16:52:51] [SYNC] [INFO] Prep complete for Flameus: 15006 examined, 300 selected, 20 tick(s), 0.50s
[16:52:51] [SYNC] [INFO] Sending 300 tx to Flameus in 325 chunk(s), capped: 310 bucket(s) deferred
[16:53:36] [SYNC] [INFO] HELLO round Strikä-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=4812tx local=15006tx hash=328011141/3760377300 buckets=334
   (sync: 628 lines starting "Chunk " elided)
   (sync: 23 lines starting "RECV " elided)
   (sync: 59 lines starting "Sending chunk " elided)
   (sync: 59 lines starting "ACK from " elided)
[12:48:29] [SYSTEM] [INFO] Scan: T1=56(event) T2=93(event) T3=87(event) T4=85(event) T5=73(event) T6=93(event) T7=80(event) (567 total, 6s)
[12:49:53] [SYSTEM] [INFO] Scan: T1=56(event) T2=93(event) T3=87(event) T4=85(event) T5=73(event) T6=93(event) T7=76(event) (563 total, 4s)
[12:52:48] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=91(event) T7=76(event) (607 total, 5s)
[12:52:59] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=91(event) T7=76(event) (607 total, 5s)
[12:53:56] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=90(event) T7=76(event) (606 total, 5s)
[12:54:08] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=76(event) (605 total, 4s)
[12:54:14] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=76(event) (605 total, 6s)
[13:44:33] [SYSTEM] [INFO] Post-scan cleanup: removed 46 duplicate record(s)
[13:44:37] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=76(event) (605 total, 6s)
[13:53:15] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=77(event) (606 total, 5s)
[13:53:35] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=76(event,locked=1) (605 total, 5s)
[13:53:40] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=76(event) (605 total, 4s)
[15:08:39] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=76(event) (605 total, 4s)
[15:14:57] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=95(event) T5=92(event) T6=89(event) T7=74(event) (603 total, 4s)
[16:15:15] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=95(event) T5=92(event) T6=89(event) T7=74(event) (602 total, 5s)
[12:49:54] [SORT] [INFO] Sort plan: 11.9ms, 118 ops, 1 deficits, 9 unplaced (input: 563 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:56 T2:93 T3:87 T4:85 T5:73 T6:93 T7:76]
[12:49:54] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=46 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=9) P3 sweep=0 P4 pack=81
[12:52:48] [SORT] [INFO] Sort plan: 5.7ms, 48 ops, 1 deficits, 4 unplaced (input: 607 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:76]
[12:52:48] [SORT] [INFO]   phases: P0 merge=15(free=2) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=37
[12:52:48] [SORT] [INFO] Sort: pass 1 left 48 move(s); re-running
[12:52:54] [SORT] [INFO] Sort: aborted (cancelled) in 134.5s - 2 passes, 124 ops issued, 0 remaining, avg 1.08s/op (cursorStuck=0 stalls=0 rescans=8)
[12:52:54] [SORT] [INFO] Sort hitch summary: 3 hitches, max 719ms [<=1000ms:1 <=150ms:2]
[12:52:54] [SORT] [INFO] Sort: net at finish - ping home 77ms / world 77ms
[12:52:59] [SORT] [INFO] Sort plan: 5.8ms, 43 ops, 1 deficits, 4 unplaced (input: 607 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:76]
[12:52:59] [SORT] [INFO]   phases: P0 merge=10(free=2) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=37
[12:52:59] [SORT] [INFO] Sort plan: 5.6ms, 43 ops, 1 deficits, 4 unplaced (input: 607 slots / 7 tabs) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:76]
[12:52:59] [SORT] [INFO]   phases: P0 merge=10(free=2) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=37
[12:53:01] [SORT] [INFO] Sort plan: 6.4ms, 43 ops, 1 deficits, 4 unplaced (input: 607 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:76]
[12:53:01] [SORT] [INFO]   phases: P0 merge=10(free=2) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=37
[12:53:02] [SORT] [INFO] Sort plan: 5.5ms, 43 ops, 1 deficits, 4 unplaced (input: 607 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:91 T7:76]
[12:53:02] [SORT] [INFO]   phases: P0 merge=10(free=2) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=37
[12:53:56] [SORT] [INFO] Sort plan: 5.7ms, 4 ops, 1 deficits, 4 unplaced (input: 606 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:90 T7:76]
[12:53:56] [SORT] [INFO]   phases: P0 merge=1(free=1) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=7
[12:53:56] [SORT] [INFO] Sort: pass 1 left 4 move(s); re-running
[12:54:08] [SORT] [INFO] Sort plan: 5.7ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[12:54:08] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[12:54:08] [SORT] [INFO] Sort: complete in 64.6s - 2 passes, 47 ops issued, 0 remaining, avg 1.37s/op (cursorStuck=0 stalls=0 rescans=3)
[12:54:08] [SORT] [INFO] Sort hitch summary: 2 hitches, max 114ms [<=150ms:2]
[12:54:08] [SORT] [INFO] Sort: net at finish - ping home 77ms / world 78ms
[12:54:14] [SORT] [INFO] Sort plan: 5.6ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[12:54:14] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[12:54:44] [SORT] [INFO] Sort plan: 5.9ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[12:54:44] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[12:54:46] [SORT] [INFO] Sort plan: 18.1ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[12:54:46] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[13:44:31] [SORT] [INFO] Sort plan: 24.4ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[13:44:31] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[13:44:32] [SORT] [INFO] Sort plan: 5.4ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[13:44:32] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[13:44:33] [SORT] [INFO] Sort plan: 6.6ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[13:44:33] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[13:53:10] [SORT] [INFO] Sort plan: 6.4ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[13:53:10] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
[13:53:11] [SORT] [INFO] Sort plan: 5.3ms, 0 ops, 1 deficits, 4 unplaced (input: 605 slots / 7 tabs) bags:0/56(fill=0,spill=0,stay=0,ignored=18,bound=38,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:95 T5:92 T6:89 T7:76]
[13:53:11] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=4) P3 sweep=0 P4 pack=4
   (sort: 258 lines starting "(sort other)" elided)
```

### Session 9: 2026-09-02 21:01:20, v0.38.1, sync dropped 4808

```text
[22:17:34] [SYNC] [INFO] HELLO round Katorrí-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=13614tx local=15091tx hash=755204839/1966485717 buckets=335
[22:18:45] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:18:45] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:18:45] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13614tx local=15091tx hash=755204839/1966485717 buckets=335
[22:18:53] [SYNC] [INFO] HELLO round Strikä-Stormrage: verdict=superset-skip reply=sync-active peer=v0.38.1 remote=4949tx local=15091tx hash=755204839/166638171 buckets=335
[22:19:15] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:19:15] [SYNC] [WARN] Could not decompress a WHISPER message from Kátorri-Stormrage (452 B); likely a lost or corrupt fragment
[22:19:35] [SYNC] [INFO] Declined sync from Kátorri-Stormrage (already sending to Flameus)
[22:19:35] [SYNC] [INFO] Sent BUSY to Kátorri-Stormrage
[22:22:20] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:22:20] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:22:20] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13614tx local=15091tx hash=755204839/1966485717 buckets=335
[22:22:34] [SYNC] [INFO] Received BUSY from Kátorri-Stormrage (reason: combat)
[22:22:52] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=13614tx local=15091tx hash=755204839/1966485717 buckets=335
[22:23:00] [SYNC] [INFO] Sent HELLO reply to Flameus (tx: 15091, hash: 755204839)
[22:23:00] [SYNC] [INFO] Nudged behind peer Flameus to pull (superset, hash-gate bypass)
[22:23:00] [SYNC] [INFO] HELLO round Flameus: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13829tx local=15091tx hash=755204839/3702912746 buckets=335
[22:23:12] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=13614tx local=15091tx hash=755204839/1966485717 buckets=335
[22:24:31] [SYNC] [INFO] Send complete to Flameus - 446/446 chunks, 399 records, 450s
[22:24:31] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 2 HELLO replies suppressed, 0 NACKs received
[22:24:31] [SYNC] [INFO] Sync outcomes for Flameus: 446 on 1st, 0 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[22:24:31] [SYNC] [INFO] Retry causes for Flameus: ackTimeout=0, nack=0, chunkFail=0.0%, p_frag=0.0% (n=1.2 frags/chunk)
[22:24:31] [SYNC] [INFO] Compression for Flameus: 52% / 68% / 71% of raw (min/med/max), 85 chunk(s) over 1 fragment
[22:24:31] [SYNC] [INFO] Wire-to-ACK for Flameus: 0.31s / 0.57s / 1.37s (min/med/max), timeout 3s
[22:24:32] [SYNC] [INFO] Sent HELLO reply to Flameus (tx: 15091, hash: 755204839)
[22:24:32] [SYNC] [INFO] Nudged behind peer Flameus to pull (superset, hash-gate bypass)
[22:24:32] [SYNC] [INFO] HELLO round Flameus: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13808tx local=15091tx hash=755204839/3377757523 buckets=335
[22:24:32] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=15091 > remote=13808)
[22:24:32] [SYNC] [INFO] Sent HELLO reply to Katorri-Stormrage (tx: 15091, hash: 755204839)
[22:24:32] [SYNC] [INFO] HELLO round Katorri-Stormrage: verdict=superset-skip reply=sent peer=v0.38.1 remote=13614tx local=15091tx hash=755204839/1966485717 buckets=335
[22:24:32] [SYNC] [INFO] Bucket filter: 335 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 18 matching, 317 differing
[22:24:32] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5721 chars)
[22:24:33] [SYNC] [INFO] Sending 10542 item tx + 4263 money tx from differing days
[22:24:33] [SYNC] [INFO] Tranche rotation for Flameus: 3 in last tranche, 3 unchanged (demoted), 0 still selected
[22:24:33] [SYNC] [INFO] Send order newest-first: 2026-09-02 20:00 back to 1969-12-31 19:00
[22:24:33] [SYNC] [INFO] Prep complete for Flameus: 15091 examined, 479 selected, 20 tick(s), 0.63s
[22:24:33] [SYNC] [INFO] Sending 479 tx to Flameus in 505 chunk(s), capped: 306 bucket(s) deferred
[22:25:16] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:29:55] [SYNC] [INFO] Combat started - aborting sync
[22:29:55] [SYNC] [INFO] Send complete to Flameus - 322/505 chunks, 479 records, 322s
[22:29:55] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 0 HELLO replies suppressed, 0 NACKs received
[22:29:55] [SYNC] [INFO] Sync outcomes for Flameus: 321 on 1st, 0 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 1 combat + 0 zone + 0 busy + 0 offline
[22:29:55] [SYNC] [INFO] Retry causes for Flameus: ackTimeout=0, nack=0, chunkFail=0.0%, p_frag=0.0% (n=1.6 frags/chunk)
[22:29:55] [SYNC] [INFO] Compression for Flameus: 60% / 67% / 70% of raw (min/med/max), 203 chunk(s) over 1 fragment
[22:29:55] [SYNC] [INFO] Wire-to-ACK for Flameus: 0.24s / 0.57s / 1.10s (min/med/max), timeout 3s
[22:29:55] [SYNC] [INFO] Sent BUSY to send target: Flameus
[22:30:07] [SYNC] [INFO] Combat cooldown complete - sync resumed
[22:30:07] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:30:52] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:30:52] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:30:52] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:30:55] [SYNC] [INFO] Declined sync from Kátorri-Stormrage (in combat) - sent BUSY
[22:31:16] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:31:16] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=n/a peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:32:48] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:32:48] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:32:48] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:33:16] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:33:17] [SYNC] [WARN] Could not decompress a WHISPER message from Kátorri-Stormrage (452 B); likely a lost or corrupt fragment
[22:33:18] [SYNC] [INFO] Received BUSY from Kátorri-Stormrage (reason: combat)
[22:33:24] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:34:48] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:34:48] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:34:48] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:34:49] [SYNC] [WARN] Could not decompress a WHISPER message from Kátorri-Stormrage (451 B); likely a lost or corrupt fragment
[22:34:50] [SYNC] [INFO] Received BUSY from Kátorri-Stormrage (reason: combat)
[22:34:57] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:35:16] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:35:17] [SYNC] [INFO] Declined sync from Kátorri-Stormrage (in combat) - sent BUSY
[22:36:47] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:36:47] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:36:47] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:37:15] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:37:23] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:38:48] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:38:48] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:38:48] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:38:49] [SYNC] [WARN] Could not decompress a WHISPER message from Kátorri-Stormrage (451 B); likely a lost or corrupt fragment
[22:39:16] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:39:39] [SYNC] [INFO] Declined sync from Kátorri-Stormrage (in combat) - sent BUSY
[22:40:48] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15091, hash: 755204839)
[22:40:48] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[22:40:48] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13623tx local=15091tx hash=755204839/1884250325 buckets=335
[22:40:49] [SYNC] [WARN] Could not decompress a WHISPER message from Kátorri-Stormrage (451 B); likely a lost or corrupt fragment
[22:41:09] [SYNC] [INFO] Declined sync from Kátorri-Stormrage (in combat) - sent BUSY
[22:41:16] [SYNC] [INFO] Sent HELLO (tx: 15091, hash: 755204839)
[22:41:17] [SYNC] [INFO] Declined sync from Voxle (in combat) - sent BUSY
   (sync: 735 lines starting "Chunk " elided)
   (sync: 28 lines starting "RECV " elided)
   (sync: 75 lines starting "Sending chunk " elided)
   (sync: 75 lines starting "ACK from " elided)
[21:16:41] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=94(event) T5=87(event) T6=89(event) T7=75(event) (597 total, 6s)
[21:23:59] [SYSTEM] [INFO] Post-scan cleanup: removed 1 duplicate record(s)
[21:24:03] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=94(event) T5=87(event) T6=89(event) T7=75(event) (597 total, 6s)
[21:27:02] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=94(event) T5=87(event) T6=89(event) T7=75(event) (597 total, 5s)
[21:30:40] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=94(event) T5=87(event) T6=89(event) T7=74(event) (596 total, 5s)
[21:46:18] [SYSTEM] [INFO] Post-scan cleanup: removed 1 duplicate record(s)
[21:46:22] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=94(event) T5=87(event) T6=89(event) T7=74(event) (596 total, 5s)
[21:47:22] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 5s)
[21:47:37] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 6s)
[21:47:46] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 5s)
[21:47:52] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 6s)
[21:46:23] [SORT] [INFO] Sort plan: 10.3ms, 43 ops, 2 deficits, 4 unplaced (input: 596 slots / 7 tabs) bags:3/61(fill=0,spill=5,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:97 T4:94 T5:87 T6:89 T7:74]
[21:46:23] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=6 P1b spill=5(top=3,r=0,l=0,fe=2,unp=0) P2 pivot=1(abort=4) P3 sweep=0 P4 pack=35
[21:46:29] [SORT] [INFO] Sort plan: 9.8ms, 43 ops, 2 deficits, 4 unplaced (input: 596 slots / 7 tabs) bags:3/61(fill=0,spill=5,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:97 T4:94 T5:87 T6:89 T7:74]
[21:46:29] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=6 P1b spill=5(top=3,r=0,l=0,fe=2,unp=0) P2 pivot=1(abort=4) P3 sweep=0 P4 pack=35
[21:47:23] [SORT] [INFO] Sort plan: 6.6ms, 5 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:47:23] [SORT] [INFO]   phases: P0 merge=1(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=6
[21:47:23] [SORT] [INFO] Sort: pass 1 left 5 move(s); re-running
[21:47:37] [SORT] [INFO] Sort plan: 22.6ms, 1 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:47:37] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=3
[21:47:37] [SORT] [INFO] Sort: pass 2 left 1 move(s); re-running
[21:47:46] [SORT] [INFO] Sort plan: 16.1ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:47:46] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:47:46] [SORT] [INFO] Sort: complete in 76.0s - 3 passes, 49 ops issued, 0 remaining, avg 1.55s/op (cursorStuck=0 stalls=0 rescans=3)
[21:47:46] [SORT] [INFO] Sort bags: 5 deposit(s) issued, 0 skipped
[21:47:46] [SORT] [INFO] Sort hitch summary: 2 hitches, max 124ms [<=150ms:2]
[21:47:46] [SORT] [INFO] Sort: net at finish - ping home 78ms / world 79ms
[21:47:52] [SORT] [INFO] Sort plan: 11.7ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:47:52] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:48:37] [SORT] [INFO] Sort plan: 9.2ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:48:37] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:48:40] [SORT] [INFO] Sort plan: 7.1ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:48:40] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:49:27] [SORT] [INFO] Sort plan: 7.2ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:49:27] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:49:41] [SORT] [INFO] Sort plan: 6.0ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:49:41] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:49:45] [SORT] [INFO] Sort plan: 6.1ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:49:45] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:50:45] [SORT] [INFO] Sort plan: 5.9ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:50:45] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:50:52] [SORT] [INFO] Sort plan: 6.9ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:50:52] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:50:56] [SORT] [INFO] Sort plan: 7.0ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:50:56] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:51:03] [SORT] [INFO] Sort plan: 5.7ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:51:03] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:51:21] [SORT] [INFO] Sort plan: 5.5ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:51:21] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
[21:51:24] [SORT] [INFO] Sort plan: 5.6ms, 0 ops, 2 deficits, 2 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[21:51:24] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=2) P3 sweep=0 P4 pack=2
   (sort: 76 lines starting "(sort other)" elided)
```

### Session 10: 2026-09-02 22:44:49, v0.38.1, sync dropped 5115

```text
[00:20:03] [SYNC] [WARN] ACK timeout, retrying chunk 81 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:20:11] [SYNC] [WARN] ACK timeout, retrying chunk 86 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:20:18] [SYNC] [WARN] ACK timeout, retrying chunk 90 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:20:25] [SYNC] [WARN] ACK timeout, retrying chunk 94 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:20:29] [SYNC] [WARN] ACK timeout, retrying chunk 95 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:20:34] [SYNC] [WARN] ACK timeout, retrying chunk 97 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:20:41] [SYNC] [WARN] ACK timeout, retrying chunk 101 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:20:44] [SYNC] [INFO] Sent HELLO (tx: 15101, hash: 1740555325)
[00:20:46] [SYNC] [WARN] ACK timeout, retrying chunk 103 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:20:52] [SYNC] [WARN] ACK timeout, retrying chunk 106 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:20:58] [SYNC] [WARN] ACK timeout, retrying chunk 109 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:21:05] [SYNC] [WARN] ACK timeout, retrying chunk 113 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:21:09] [SYNC] [WARN] ACK timeout, retrying chunk 114 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:21:26] [SYNC] [WARN] ACK timeout, retrying chunk 128 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:21:32] [SYNC] [WARN] ACK timeout, retrying chunk 131 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:21:36] [SYNC] [WARN] ACK timeout, retrying chunk 132 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:21:42] [SYNC] [WARN] ACK timeout, retrying chunk 135 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:21:51] [SYNC] [WARN] ACK timeout, retrying chunk 141 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:21:55] [SYNC] [WARN] ACK timeout, retrying chunk 142 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:21:59] [SYNC] [WARN] ACK timeout, retrying chunk 143 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:22:04] [SYNC] [WARN] ACK timeout, retrying chunk 145 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:22:46] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15101, hash: 1740555325)
[00:22:46] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[00:22:46] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13681tx local=15101tx hash=1740555325/2320101313 buckets=335
[00:23:21] [SYNC] [WARN] ACK timeout, retrying chunk 218 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:23:25] [SYNC] [WARN] ACK timeout, retrying chunk 219 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:23:30] [SYNC] [WARN] ACK timeout, retrying chunk 221 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:23:41] [SYNC] [WARN] ACK timeout, retrying chunk 229 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:23:52] [SYNC] [WARN] ACK timeout, retrying chunk 237 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:23:57] [SYNC] [WARN] ACK timeout, retrying chunk 239 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:24:02] [SYNC] [WARN] ACK timeout, retrying chunk 241 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:24:08] [SYNC] [WARN] ACK timeout, retrying chunk 244 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:24:12] [SYNC] [WARN] ACK timeout, retrying chunk 245 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:25:24] [SYNC] [WARN] ACK timeout, retrying chunk 313 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:25:42] [SYNC] [WARN] ACK timeout, retrying chunk 328 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:25:47] [SYNC] [WARN] ACK timeout, retrying chunk 330 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:25:54] [SYNC] [WARN] ACK timeout, retrying chunk 334 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:26:19] [SYNC] [WARN] ACK timeout, retrying chunk 356 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:26:31] [SYNC] [WARN] ACK timeout, retrying chunk 364 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:26:35] [SYNC] [WARN] ACK timeout, retrying chunk 365 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:26:45] [SYNC] [INFO] Sent HELLO (tx: 15102, hash: 1424199127)
[00:27:17] [SYNC] [WARN] ACK timeout, retrying chunk 404 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:27:18] [SYNC] [INFO] Send complete to Kátorri-Stormrage - 404/404 chunks, 369 records, 582s
[00:27:18] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 0 HELLO replies suppressed, 0 NACKs received
[00:27:18] [SYNC] [INFO] Sync outcomes for Kátorri-Stormrage: 346 on 1st, 58 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 0 offline
[00:27:18] [SYNC] [INFO] Retry causes for Kátorri-Stormrage: ackTimeout=58, nack=0, chunkFail=12.6%, p_frag=8.7% (n=1.5 frags/chunk)
[00:27:18] [SYNC] [INFO] Compression for Kátorri-Stormrage: 51% / 66% / 70% of raw (min/med/max), 193 chunk(s) over 1 fragment
[00:27:18] [SYNC] [INFO] Wire-to-ACK for Kátorri-Stormrage: 0.37s / 0.62s / 0.79s (min/med/max), timeout 3s
[00:27:18] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=15102 > remote=13681)
[00:27:18] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15102, hash: 1424199127)
[00:27:18] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, bidirectional hash-gate bypass)
[00:27:19] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-skip reply=hash-suppressed peer=v0.38.1 remote=13671tx local=15102tx hash=1424199127/1585266118 buckets=335
[00:27:19] [SYNC] [INFO] Bucket filter: 335 local bucket(s), 50 remote detail bucket(s), 8 span(s) (8 differing), 14 matching, 321 differing
[00:27:19] [SYNC] [INFO] Differing dates: 1969-12-31 19:00, 2026-01-15 19:00, 2026-01 ...(5793 chars)
[00:27:20] [SYNC] [INFO] Sending 10449 item tx + 4302 money tx from differing days
[00:27:20] [SYNC] [INFO] Tranche rotation for Kátorri-Stormrage: 12 in last tranche, 11 unchanged (demoted), 0 still selected
[00:27:20] [SYNC] [INFO] Send order newest-first: 2026-09-02 20:00 back to 1969-12-31 19:00
[00:27:20] [SYNC] [INFO] Prep complete for Kátorri-Stormrage: 15102 examined, 349 selected, 30 tick(s), 0.74s
[00:27:20] [SYNC] [INFO] Sending 349 tx to Kátorri-Stormrage in 385 chunk(s), capped: 319 bucket(s) deferred
[00:27:26] [SYNC] [WARN] ACK timeout, retrying chunk 4 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:27:34] [SYNC] [WARN] ACK timeout, retrying chunk 9 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:27:41] [SYNC] [WARN] ACK timeout, retrying chunk 13 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:27:45] [SYNC] [WARN] ACK timeout, retrying chunk 14 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:27:58] [SYNC] [WARN] ACK timeout, retrying chunk 24 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:28:02] [SYNC] [WARN] ACK timeout, retrying chunk 25 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:28:07] [SYNC] [WARN] ACK timeout, retrying chunk 27 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:28:21] [SYNC] [WARN] ACK timeout, retrying chunk 38 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:28:25] [SYNC] [WARN] ACK timeout, retrying chunk 39 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:28:34] [SYNC] [WARN] ACK timeout, retrying chunk 45 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:28:45] [SYNC] [WARN] ACK timeout, retrying chunk 53 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:28:52] [SYNC] [WARN] ACK timeout, retrying chunk 57 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:28:56] [SYNC] [WARN] ACK timeout, retrying chunk 58 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:29:06] [SYNC] [WARN] ACK timeout, retrying chunk 65 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:29:11] [SYNC] [WARN] ACK timeout, retrying chunk 66 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:29:19] [SYNC] [WARN] ACK timeout, retrying chunk 71 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:32:22] [SYNC] [WARN] ACK timeout, retrying chunk 250 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:32:45] [SYNC] [INFO] Sent HELLO (tx: 15120, hash: 1839301728)
[00:32:46] [SYNC] [INFO] Sent HELLO reply to Kátorri-Stormrage (tx: 15120, hash: 1839301728)
[00:32:46] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, hash-gate bypass)
[00:32:46] [SYNC] [INFO] HELLO round Kátorri-Stormrage: verdict=superset-nudge reply=hash-suppressed peer=v0.38.1 remote=13672tx local=15120tx hash=1839301728/1830843436 buckets=335
[00:33:33] [SYNC] [WARN] ACK timeout, retrying chunk 317 (attempt 2/11), fragments~=2, gapSinceWire=3.00s, nacksThisChunk=0, target=online
[00:33:41] [SYNC] [WARN] ACK timeout, retrying chunk 322 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:34:08] [SYNC] [WARN] ACK timeout, retrying chunk 346 (attempt 2/11), fragments~=2, gapSinceWire=3.02s, nacksThisChunk=0, target=online
[00:34:26] [SYNC] [WARN] ACK timeout, retrying chunk 361 (attempt 2/11), fragments~=2, gapSinceWire=3.01s, nacksThisChunk=0, target=online
[00:34:34] [SYNC] [WARN] ACK timeout, retrying chunk 366 (attempt 2/11), fragments~=1, gapSinceWire=3.00s, nacksThisChunk=0, target=offline
[00:34:34] [SYNC] [INFO] Blocked whisper to offline player: Kátorri-Stormrage
[00:34:34] [SYNC] [ERROR] Target Kátorri-Stormrage went offline, aborting send
[00:34:34] [SYNC] [INFO] Send complete to Kátorri-Stormrage - 366/385 chunks, 349 records, 434s
[00:34:34] [SYNC] [INFO] Sync stats: 0 CTL deferrals, 0 overlapped timers, longest stall 0.0s, 0 HELLO replies suppressed, 0 NACKs received
[00:34:34] [SYNC] [INFO] Sync outcomes for Kátorri-Stormrage: 344 on 1st, 21 on 2nd, 0 on 3rd+, aborted: 0 ackTimeout + 0 combat + 0 zone + 0 busy + 1 offline
[00:34:34] [SYNC] [INFO] Retry causes for Kátorri-Stormrage: ackTimeout=22, nack=0, chunkFail=5.7%, p_frag=4.6% (n=1.2 frags/chunk)
[00:34:34] [SYNC] [INFO] Compression for Kátorri-Stormrage: 52% / 68% / 70% of raw (min/med/max), 87 chunk(s) over 1 fragment
[00:34:34] [SYNC] [INFO] Wire-to-ACK for Kátorri-Stormrage: 0.35s / 0.62s / 0.74s (min/med/max), timeout 3s
[00:34:35] [SYNC] [INFO] Bidirectional check: skipped - likely superset (local=15122 > remote=13672)
[00:34:35] [SYNC] [INFO] Blocked whisper to offline player: Kátorri-Stormrage
[00:34:35] [SYNC] [INFO] Nudged behind peer Kátorri-Stormrage to pull (superset, bidirectional hash-gate bypass)
[00:34:45] [SYNC] [INFO] Sent HELLO (tx: 15123, hash: 1412624530)
[00:36:45] [SYNC] [INFO] Sent HELLO (tx: 15123, hash: 1412624530)
[00:38:45] [SYNC] [INFO] Sent HELLO (tx: 15123, hash: 1412624530)
[00:40:45] [SYNC] [INFO] Sent HELLO (tx: 15123, hash: 1412624530)
[00:42:45] [SYNC] [INFO] Sent HELLO (tx: 15123, hash: 1412624530)
[00:44:45] [SYNC] [INFO] Sent HELLO (tx: 15123, hash: 1412624530)
   (sync: 749 lines starting "Chunk " elided)
   (sync: 4 lines starting "RECV " elided)
   (sync: 74 lines starting "Sending chunk " elided)
   (sync: 71 lines starting "ACK from " elided)
[22:45:13] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 6s)
[22:55:16] [SYSTEM] [INFO] Post-scan cleanup: removed 7 duplicate record(s)
[22:55:20] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=94(event) T5=92(event) T6=91(event) T7=74(event) (604 total, 5s)
[00:09:29] [SYSTEM] [INFO] Post-scan cleanup: removed 42 duplicate record(s)
[00:09:33] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=98(event) T4=93(event) T5=92(event) T6=91(event) T7=74(event) (603 total, 5s)
[00:45:12] [SYSTEM] [INFO] Post-scan cleanup: removed 17 duplicate record(s)
[00:45:16] [SYSTEM] [INFO] Scan: T1=57(event) T2=98(event) T3=97(event) T4=93(event) T5=92(event) T6=91(event) T7=74(event) (602 total, 5s)
[22:45:18] [SORT] [INFO] Sort plan: 6.1ms, 18 ops, 2 deficits, 0 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[22:45:18] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=14 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=4
[22:45:25] [SORT] [INFO] Sort plan: 7.2ms, 18 ops, 2 deficits, 0 unplaced (input: 604 slots / 7 tabs) bags:0/58(fill=0,spill=0,stay=0,ignored=17,bound=41,locked=0,nolink=0) [T1:57 T2:98 T3:98 T4:94 T5:92 T6:91 T7:74]
[22:45:25] [SORT] [INFO]   phases: P0 merge=0(free=0) P1a assign=14 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=4
   (sort: 2 lines starting "(sort other)" elided)
```
