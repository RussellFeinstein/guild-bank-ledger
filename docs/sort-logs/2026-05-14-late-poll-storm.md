# Sort log: 2026-05-14 late-poll storm + replan-cap abort

- **Date**: 2026-05-14
- **Addon version**: 0.32.3
- **Bank**: 7 tabs / 515 slots
- **Source**: in-game capture of two consecutive `/gbl` sort runs against the same bank state.

## Run summary

**Run A (21:23:01 to 21:26:45, 223.5s)**. Aborted at replan 5/5. 4 ops done, 43 failed, 5 replans, 1 reclassify. Trigger logged as "dst occupied by wrong item at op N" repeating on the same chain. Op 1 succeeded in 0.8s via the fast `[sync]` / `[async]` path; every subsequent op timed out or no-op'd.

**Run B (21:29:23 to 21:34:13, 290.2s)**. Completed 64/64 ops. Op 1 was confirmed by a late event after timeout (reclassified at lines 676-691 in `src/SortExecutor.lua`); ops 2-64 every single one shows `(4.0s) [late-poll]` in the success line. No op in Run B confirmed via the fast event-driven path.

## Diagnosis summary

Six load-bearing observations. Each names the file:line in the current tree so a future investigation can land in the right place without grepping the whole executor.

1. **Late-poll dominance is real but intermittent.** Run B ops 2-64 all confirmed via the `[late-poll]` poll at the 4.0s `MOVE_CONFIRM_TIMEOUT` floor (`src/SortExecutor.lua:588-658`). Run A op 1 confirmed in 0.8s via the fast `[sync]` path. The failure is state-dependent, not wholesale event loss.

2. **OnSlotsChanged fires; advance predicates reject.** The handler at `src/SortExecutor.lua:665-770` runs on every retail event in both runs (proven by the dozens of `no-op suspected [async]` audit lines in the raw log). The cursor-empty gate at line 702 plus the `srcDrainedAsExpected` check at line 709 reject in-flight events that arrive before the server-side merge resolves. The `[late-poll]` path then catches the success at 4.0s. Question for the next pass: are retail events arriving with `cursorHeld=true` consistently (which would suggest a one-tick re-check), or is `srcDrainedAsExpected` returning false at the event-time slot read because the live API call inside the handler races the server update?

3. **Singleton-chain emit pattern.** Run A ops 28-32 emit a Gateway Control Shard x1 chain T6/S6 to S5 to S4 to S3 to S2 to S1. Observed at each step: `src Gateway Control Shard x1, dst Gateway Control Shard x1, cursor empty`. Max stack is 1; the server refuses the merge; both slots end with the item; src never drains. `srcDrainedAsExpected` correctly fires no-op suspected. The interesting question is why the planner emitted this chain at all. Either the planner snapshot saw multiple instances of this unique item, or the planner's `applyOpToState` advanced past an op the executor flagged as no-op without the planner's projected state ever being rolled back. Investigate `src/SortPlanner.lua` (the `plannerSrcAt` / `plannerDstAt` freeze at plan-emit) plus the planner-expected pre-state line in each op's audit.

4. **Planner state desync on splits.** Flawless gem splits in Run A show `planner expected: src x6, observed: src x7` style mismatches (drift of 1 per split, visible on Flawless Quick Amethyst at T6/S16 and Flawless Quick Garnet at T6/S17). Same root-cause family as bullet 3: planner's frozen projection drifts from live state when an earlier op the planner counted as completed was a no-op in the executor's eyes.

5. **`[other]` timeout bucket is overloaded.** Run A: `timeout[n=0,p=0,c=0,o=44]`. Run B: `timeout[n=0,p=0,c=0,o=2]`. The same-item-stuck-merge case (src has expected item, dst has expected item, cursor empty) currently falls into the catchall at `src/SortExecutor.lua:167`. Adding a fifth classification (e.g. `"refused"` for the `srcHasExpected && dstHasExpected && !cursorHasItem` shape) would expose singleton-chain pathologies directly in the abort-line audit without reading the per-op trace.

6. **Replan cap is the fuse, not the bug.** Run A hit 5/5 because every replan rebuilt the same plan against the same broken live state. `MAX_REPLANS` at `src/SortExecutor.lua:34` is sized correctly; the upstream failure is the executor catching no-ops while the planner re-emits them.

## Open questions for the next investigation pass

- Add a counter in `OnSlotsChanged` for events received during sort vs events that advanced state. The current audit has only the rejection side; the firing side is implicit.
- Is the 4.0s `MOVE_CONFIRM_TIMEOUT` too tight for retail server processing of this guild bank, or is the rejection coming from predicate strictness rather than server latency? A wider timeout would tell us, but only if the cause is latency.
- Did Run A's Gateway Control Shard chain reflect a planner snapshot that saw two instances of a unique item, or did the planner's projected post-state advance past an executor-flagged no-op without rollback? Compare the saved bank layout against the actual snapshot at run start.
- Should the `[other]` timeout bucket be split into `refused`, `pickup-failed`, and a smaller residual `other` so the abort summary names the failure shape on a single line?
- Server-reversion detection (`src/SortExecutor.lua:733-768`) emitted no "server reversion suspected" warnings in either run. Either the chain never reverted server-side and the planner emit was the bug from the start, or the detector's `lastCompletedOp` projection happened to match the no-op state and missed the reversion. Worth instrumenting alongside the OnSlotsChanged event counter.

## Raw log

Pasted verbatim from the in-game capture, newest at top. Timestamps are local server time.

```
[21:35:57]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:35:57]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=0
[21:35:57] Sort plan: 5.9ms, 0 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:34:18]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:34:18]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=63
[21:34:18] Sort plan: 6.0ms, 64 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:34:13] Sort: complete in 290.2s - 64 ops (65 done, 1 failed, 1 replans, 1 reclass) preCheck=1 cursor=0 timeout[n=0,p=0,c=0,o=2] avg 4.40s/op
[21:34:13] Sort op 64 done: move T6/S81->T6/S45 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:34:09] Sort op 63 done: move T6/S45->T6/S51 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:34:04] Sort op 62 done: move T6/S51->T6/S58 Enchant Helm - Empowered Hex of Leeching (it:243951) x6 (4.0s) [late-poll] src=empty dst=Enchant Helm - Empowered Hex of Leeching (it:243951) x6
[21:34:00] Sort op 61 done: move T6/S58->T6/S64 Enchant Chest - Mark of the Worldsoul (it:243977) x11 (4.0s) [late-poll] src=empty dst=Enchant Chest - Mark of the Worldsoul (it:243977) x11
[21:33:56] Sort op 60 done: move T6/S64->T6/S70 Enchant Helm - Empowered Rune of Avoidance (it:244007) x6 (4.0s) [late-poll] src=empty dst=Enchant Helm - Empowered Rune of Avoidance (it:244007) x6
[21:33:51] Sort op 59 done: move T6/S70->T6/S76 Enchant Weapon - Arcane Mastery (it:244031) x2 (4.0s) [late-poll] src=empty dst=Enchant Weapon - Arcane Mastery (it:244031) x2
[21:33:47] Sort op 58 done: move T6/S76->T6/S40 Light's Potential (it:241309) x200 (4.0s) [late-poll] src=empty dst=Light's Potential (it:241309) x200
[21:33:43] Sort op 57 done: move T6/S40->T6/S47 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:33:38] Sort op 56 done: move T6/S47->T6/S53 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:33:34] Sort op 55 done: move T6/S53->T6/S60 Enchant Ring - Eyes of the Eagle (it:243957) x6 (4.0s) [late-poll] src=empty dst=Enchant Ring - Eyes of the Eagle (it:243957) x6
[21:33:30] Sort op 54 done: move T6/S60->T6/S66 Enchant Boots - Shaladrassil's Roots (it:243983) x6 (4.0s) [late-poll] src=empty dst=Enchant Boots - Shaladrassil's Roots (it:243983) x6
[21:33:25] Sort op 53 done: move T6/S66->T6/S72 Enchant Ring - Silvermoon's Alacrity (it:244015) x7 (4.0s) [late-poll] src=empty dst=Enchant Ring - Silvermoon's Alacrity (it:244015) x7
[21:33:21] Sort op 52 done: move T6/S72->T6/S78 Blood Knight's Armor Kit (it:244643) x6 (4.0s) [late-poll] src=empty dst=Blood Knight's Armor Kit (it:244643) x6
[21:33:17] Sort op 51 done: move T6/S78->T6/S42 Light's Potential (it:241309) x200 (4.0s) [late-poll] src=empty dst=Light's Potential (it:241309) x200
[21:33:12] Sort op 50 done: move T6/S42->T6/S48 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:33:08] Sort op 49 done: move T6/S48->T6/S54 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:33:04] Sort op 48 done: move T6/S54->T6/S61 Enchant Ring - Zul'jin's Mastery (it:243959) x6 (4.0s) [late-poll] src=empty dst=Enchant Ring - Zul'jin's Mastery (it:243959) x6
[21:32:59] Sort op 47 done: move T6/S61->T6/S67 Enchant Ring - Nature's Fury (it:243987) x6 (4.0s) [late-poll] src=empty dst=Enchant Ring - Nature's Fury (it:243987) x6
[21:32:55] Sort op 46 done: move T6/S67->T6/S73 Enchant Ring - Silvermoon's Tenacity (it:244017) x16 (4.0s) [late-poll] src=empty dst=Enchant Ring - Silvermoon's Tenacity (it:244017) x16
[21:32:51] Sort op 45 done: move T6/S73->T6/S79 Vantus Rune: Radiant (it:245880) x4 (4.0s) [late-poll] src=empty dst=Vantus Rune: Radiant (it:245880) x4
[21:32:47] Sort op 44 done: move T6/S79->T6/S43 Light's Potential (it:241309) x200 (4.0s) [late-poll] src=empty dst=Light's Potential (it:241309) x200
[21:32:42] Sort op 43 done: move T6/S43->T6/S49 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:32:38] Sort op 42 done: move T6/S49->T6/S55 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:32:34] Sort op 41 done: move T6/S55->T6/S62 Enchant Shoulders - Akil'zon's Swiftness (it:243963) x6 (4.0s) [late-poll] src=empty dst=Enchant Shoulders - Akil'zon's Swiftness (it:243963) x6
[21:32:29] Sort op 40 done: move T6/S62->T6/S68 Enchant Shoulders - Amirdrassil's Grace (it:243991) x6 (4.0s) [late-poll] src=empty dst=Enchant Shoulders - Amirdrassil's Grace (it:243991) x6
[21:32:25] Sort op 39 done: move T6/S68->T6/S74 Enchant Shoulders - Silvermoon's Mending (it:244021) x6 (4.0s) [late-poll] src=empty dst=Enchant Shoulders - Silvermoon's Mending (it:244021) x6
[21:32:21] Sort op 38 done: move T6/S74->T6/S80 Silvermoon Parade (it:255845) x4 (4.0s) [late-poll] src=empty dst=Silvermoon Parade (it:255845) x4
[21:32:16] Sort op 37 done: move T6/S80->T6/S37 Silvermoon Health Potion (it:241305) x200 (4.0s) [late-poll] src=empty dst=Silvermoon Health Potion (it:241305) x200
[21:32:12] Sort op 36 done: move T6/S37->T6/S38 Silvermoon Health Potion (it:241305) x20 (4.0s) [late-poll] src=empty dst=Silvermoon Health Potion (it:241305) x20
[21:32:08] Sort op 35 done: move T6/S38->T6/S81 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:32:03] Sort op 34 done: move T6/S81->T6/S32 Lightfused Mana Potion (it:241301) x20 (4.0s) [late-poll] src=empty dst=Lightfused Mana Potion (it:241301) x20
[21:31:59] Sort op 33 done: move T6/S32->T6/S31 Lightfused Mana Potion (it:241301) x200 (4.0s) [late-poll] src=empty dst=Lightfused Mana Potion (it:241301) x200
[21:31:55] Sort op 32 done: move T6/S31->T6/S30 Lightfused Mana Potion (it:241301) x200 (4.0s) [late-poll] src=empty dst=Lightfused Mana Potion (it:241301) x200
[21:31:50] Sort op 31 done: move T6/S30->T6/S29 Lightfused Mana Potion (it:241301) x200 (4.0s) [late-poll] src=empty dst=Lightfused Mana Potion (it:241301) x200
[21:31:46] Sort op 30 done: move T6/S29->T6/S28 Lightfused Mana Potion (it:241301) x200 (4.0s) [late-poll] src=empty dst=Lightfused Mana Potion (it:241301) x200
[21:31:42] Sort op 29 done: move T6/S28->T6/S27 Lightfused Mana Potion (it:241301) x200 (4.0s) [late-poll] src=empty dst=Lightfused Mana Potion (it:241301) x200
[21:31:37] Sort op 28 done: move T6/S27->T6/S26 Indecipherable Eversong Diamond (it:240983) x3 (4.0s) [late-poll] src=empty dst=Indecipherable Eversong Diamond (it:240983) x3
[21:31:33] Sort op 27 done: move T6/S26->T6/S25 Stoic Eversong Diamond (it:240971) x3 (4.0s) [late-poll] src=empty dst=Stoic Eversong Diamond (it:240971) x3
[21:31:29] Sort op 26 done: move T6/S25->T6/S24 Telluric Eversong Diamond (it:240969) x3 (4.0s) [late-poll] src=empty dst=Telluric Eversong Diamond (it:240969) x3
[21:31:24] Sort op 25 done: move T6/S24->T6/S21 Flawless Deadly Lapis (it:240914) x10 (4.0s) [late-poll] src=empty dst=Flawless Deadly Lapis (it:240914) x10
[21:31:20] Sort op 24 done: move T6/S21->T6/S20 Flawless Versatile Lapis (it:240912) x3 (4.0s) [late-poll] src=empty dst=Flawless Versatile Lapis (it:240912) x3
[21:31:16] Sort op 23 done: move T6/S20->T6/S16 Flawless Deadly Garnet (it:240904) x5 (4.0s) [late-poll] src=empty dst=Flawless Deadly Garnet (it:240904) x5
[21:31:11] Sort op 22 done: move T6/S16->T6/S14 Flawless Quick Amethyst (it:240900) x3 (4.0s) [late-poll] src=empty dst=Flawless Quick Amethyst (it:240900) x3
[21:31:07] Sort op 21 done: move T6/S14->T6/S13 Flawless Deadly Amethyst (it:240898) x5 (4.0s) [late-poll] src=empty dst=Flawless Deadly Amethyst (it:240898) x5
[21:31:03] Sort op 20 done: move T6/S13->T6/S12 Flawless Masterful Amethyst (it:240896) x3 (4.0s) [late-poll] src=empty dst=Flawless Masterful Amethyst (it:240896) x3
[21:30:59] Sort op 19 done: move T6/S12->T6/S11 Flawless Versatile Peridot (it:240894) x5 (4.0s) [late-poll] src=empty dst=Flawless Versatile Peridot (it:240894) x5
[21:30:54] Sort op 18 done: move T6/S11->T6/S10 Flawless Masterful Peridot (it:240892) x5 (4.0s) [late-poll] src=empty dst=Flawless Masterful Peridot (it:240892) x5
[21:30:50] Sort op 17 done: move T6/S10->T6/S9 Flawless Deadly Peridot (it:240890) x8 (4.0s) [late-poll] src=empty dst=Flawless Deadly Peridot (it:240890) x8
[21:30:46] Sort op 16 done: move T6/S9->T6/S8 Flawless Quick Peridot (it:240888) x5 (4.0s) [late-poll] src=empty dst=Flawless Quick Peridot (it:240888) x5
[21:30:41] Sort op 15 done: move T6/S8->T6/S7 Arcanoweave Spellthread (it:240155) x6 (4.0s) [late-poll] src=empty dst=Arcanoweave Spellthread (it:240155) x6
[21:30:37] Sort op 14 done: move T6/S7->T6/S57 Thalassian Phoenix Oil (it:243733) x15 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x15
[21:30:33] Sort op 13 done: move T6/S57->T6/S63 Enchant Weapon - Berserker's Rage (it:243973) x4 (4.0s) [late-poll] src=empty dst=Enchant Weapon - Berserker's Rage (it:243973) x4
[21:30:28] Sort op 12 done: move T6/S63->T6/S69 Enchant Chest - Mark of the Magister (it:244003) x6 (4.0s) [late-poll] src=empty dst=Enchant Chest - Mark of the Magister (it:244003) x6
[21:30:24] Sort op 11 done: move T6/S69->T6/S75 Enchant Weapon - Acuity of the Ren'dorei (it:244029) x3 (4.0s) [late-poll] src=empty dst=Enchant Weapon - Acuity of the Ren'dorei (it:244029) x3
[21:30:20] Sort op 10 done: move T6/S75->T6/S39 Light's Potential (it:241309) x200 (4.0s) [late-poll] src=empty dst=Light's Potential (it:241309) x200
[21:30:15] Sort op 9 done: move T6/S39->T6/S46 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:30:11] Sort op 8 done: move T6/S46->T6/S52 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:30:07] Sort op 7 done: move T6/S52->T6/S59 Enchant Boots - Lynx's Dexterity (it:243953) x7 (4.0s) [late-poll] src=empty dst=Enchant Boots - Lynx's Dexterity (it:243953) x7
[21:30:02] Sort op 6 done: move T6/S59->T6/S65 Enchant Helm - Empowered Blessing of Speed (it:243981) x6 (4.0s) [late-poll] src=empty dst=Enchant Helm - Empowered Blessing of Speed (it:243981) x6
[21:29:58] Sort op 5 done: move T6/S65->T6/S71 Enchant Boots - Farstrider's Hunt (it:244009) x6 (4.0s) [late-poll] src=empty dst=Enchant Boots - Farstrider's Hunt (it:244009) x6
[21:29:54] Sort op 4 done: move T6/S71->T6/S77 Forest Hunter's Armor Kit (it:244641) x6 (4.0s) [late-poll] src=empty dst=Forest Hunter's Armor Kit (it:244641) x6
[21:29:49] Sort op 3 done: move T6/S77->T6/S41 Light's Potential (it:241309) x200 (4.0s) [late-poll] src=empty dst=Light's Potential (it:241309) x200
[21:29:45] Sort op 2 done: move T6/S41->T6/S44 Light's Potential (it:241309) x20 (4.0s) [late-poll] src=empty dst=Light's Potential (it:241309) x20
[21:29:41] Sort op 1 done: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (4.0s) [late-poll] src=empty dst=Thalassian Phoenix Oil (it:243733) x20
[21:29:37]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:29:37]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=63
[21:29:37] Sort plan: 4.8ms, 64 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:29:31] Sort: replan 1/5 (dst occupied by wrong item at op 3)
[21:29:31] [WARN]   op 3 was: move T6/S41 -> T6/S44 Light's Potential (it:241309) x20
[21:29:31] [WARN]   planner expected dst at emit: empty
[21:29:31] [WARN] Sort op 3/65 pre-check fail dst T6/S44: expected empty or Light's Potential (it:241309), got Thalassian Phoenix Oil (it:243733) x20
[21:29:31] [WARN]   planner expected: src Thalassian Phoenix Oil (it:243733) x20, dst empty
[21:29:31] [WARN]   observed: src Thalassian Phoenix Oil (it:243733) x20, dst empty, cursor empty
[21:29:31] [WARN]   op 2 was: move T6/S44 -> T6/S50 Thalassian Phoenix Oil (it:243733) x20
[21:29:31] [WARN] Sort: op 2 timed out (no confirm within 4s) [other]
[21:29:30] Sort: op 1 confirmed by late event after timeout - reclassified as success
[21:29:29] [WARN] Sort op 2 no-op suspected [async]: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (dst already held expected item; src unchanged)
[21:29:28] [WARN] Sort op 2 no-op suspected [async]: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (dst already held expected item; src unchanged)
[21:29:28] [WARN] Sort op 2 no-op suspected [async]: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (dst already held expected item; src unchanged)
[21:29:27] [WARN] Sort op 2 no-op suspected [async]: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (dst already held expected item; src unchanged)
[21:29:27] [WARN] Sort op 2 no-op suspected [sync]: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (dst already held expected item; src unchanged)
[21:29:27] [WARN] Sort op 2 no-op suspected [async]: move T6/S44->T6/S50 Thalassian Phoenix Oil (it:243733) x20 (dst already held expected item; src unchanged)
[21:29:27] [WARN]   planner expected: src Thalassian Phoenix Oil (it:243733) x20, dst empty
[21:29:27] [WARN]   observed: src Thalassian Phoenix Oil (it:243733) x20, dst empty, cursor empty
[21:29:27] [WARN]   op 1 was: move T6/S50 -> T6/S56 Thalassian Phoenix Oil (it:243733) x20
[21:29:27] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[21:29:23] Sort: starting execution of 65 ops
[21:29:01]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:29:01]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=64
[21:29:01] Sort plan: 17.1ms, 65 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:26:50]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:26:50]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=64
[21:26:50] Sort plan: 5.1ms, 65 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:26:50]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:26:50]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=64
[21:26:50] Sort plan: 5.5ms, 65 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:26:45] Sort: aborted (replan cap exceeded (dst occupied by wrong item at op 2)) in 223.5s - 66 ops (4 done, 43 failed, 5 replans, 1 reclass) preCheck=6 cursor=0 timeout[n=0,p=0,c=0,o=44] avg 4.75s/op
[21:26:45] [WARN]   op 2 was: move T6/S50 -> T6/S56 Thalassian Phoenix Oil (it:243733) x20
[21:26:45] [WARN]   planner expected dst at emit: empty
[21:26:45] [WARN] Sort op 2/66 pre-check fail dst T6/S56: expected empty or Thalassian Phoenix Oil (it:243733), got Sunfire Silk Spellthread (it:240133) x6
[21:26:44] [WARN]   planner expected: src Sunfire Silk Spellthread (it:240133) x6, dst empty
[21:26:44] [WARN]   observed: src Sunfire Silk Spellthread (it:240133) x6, dst empty, cursor empty
[21:26:44] [WARN]   op 1 was: move T6/S56 -> T6/S6 Sunfire Silk Spellthread (it:240133) x6
[21:26:44] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[21:26:40]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:26:40]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=65
[21:26:40] Sort plan: 7.0ms, 66 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:26:35] Sort: replan 5/5 (dst occupied by wrong item at op 2)
[21:26:35] [WARN]   op 2 was: move T6/S56 -> T6/S6 Sunfire Silk Spellthread (it:240133) x6
[21:26:35] [WARN]   planner expected dst at emit: empty
[21:26:35] [WARN] Sort op 2/67 pre-check fail dst T6/S6: expected empty or Sunfire Silk Spellthread (it:240133), got Gateway Control Shard (it:188152) x1
[21:26:35] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:26:35] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst empty, cursor empty
[21:26:35] [WARN]   op 1 was: move T6/S6 -> T6/S5 Gateway Control Shard (it:188152) x1
[21:26:35] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[21:26:31]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:26:31]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=66
[21:26:31] Sort plan: 5.5ms, 67 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:26:26] Sort: replan 4/5 (dst occupied by wrong item at op 3)
[21:26:26] [WARN]   op 3 was: move T6/S56 -> T6/S6 Sunfire Silk Spellthread (it:240133) x6
[21:26:26] [WARN]   planner expected dst at emit: empty
[21:26:26] [WARN] Sort op 3/68 pre-check fail dst T6/S6: expected empty or Sunfire Silk Spellthread (it:240133), got Gateway Control Shard (it:188152) x1
[21:26:25] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:26:25] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:26:25] [WARN]   op 2 was: move T6/S6 -> T6/S5 Gateway Control Shard (it:188152) x1
[21:26:25] [WARN] Sort: op 2 timed out (no confirm within 4s) [other]
[21:26:21] [WARN] Sort op 2 no-op suspected [sync]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:26:21] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:26:21] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst empty, cursor empty
[21:26:21] [WARN]   op 1 was: move T6/S5 -> T6/S4 Gateway Control Shard (it:188152) x1
[21:26:21] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[21:26:17]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:26:17]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=67
[21:26:17] Sort plan: 15.4ms, 68 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:26:12] Sort: replan 3/5 (dst occupied by wrong item at op 4)
[21:26:12] [WARN]   op 4 was: move T6/S56 -> T6/S6 Sunfire Silk Spellthread (it:240133) x6
[21:26:12] [WARN]   planner expected dst at emit: empty
[21:26:12] [WARN] Sort op 4/69 pre-check fail dst T6/S6: expected empty or Sunfire Silk Spellthread (it:240133), got Gateway Control Shard (it:188152) x1
[21:26:11] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:26:11] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:26:11] [WARN]   op 3 was: move T6/S6 -> T6/S5 Gateway Control Shard (it:188152) x1
[21:26:11] [WARN] Sort: op 3 timed out (no confirm within 4s) [other]
[21:26:07] [WARN] Sort op 3 no-op suspected [sync]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:26:07] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:26:07] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:26:07] [WARN]   op 2 was: move T6/S5 -> T6/S4 Gateway Control Shard (it:188152) x1
[21:26:07] [WARN] Sort: op 2 timed out (no confirm within 4s) [other]
[21:26:03] [WARN] Sort op 2 no-op suspected [sync]: move T6/S5->T6/S4 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:26:03] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:26:03] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst empty, cursor empty
[21:26:03] [WARN]   op 1 was: move T6/S4 -> T6/S3 Gateway Control Shard (it:188152) x1
[21:26:03] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[21:25:59]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:25:59]   phases: P0 merge=0(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=68
[21:25:59] Sort plan: 5.1ms, 69 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:25:53] Sort: replan 2/5 (dst occupied by wrong item at op 9)
[21:25:53] [WARN]   op 9 was: move T6/S56 -> T6/S6 Sunfire Silk Spellthread (it:240133) x6
[21:25:53] [WARN]   planner expected dst at emit: empty
[21:25:53] [WARN] Sort op 9/74 pre-check fail dst T6/S6: expected empty or Sunfire Silk Spellthread (it:240133), got Gateway Control Shard (it:188152) x1
[21:25:53] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:53] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:53] [WARN]   op 8 was: move T6/S6 -> T6/S5 Gateway Control Shard (it:188152) x1
[21:25:53] [WARN] Sort: op 8 timed out (no confirm within 4s) [other]
[21:25:49] [WARN] Sort op 8 no-op suspected [sync]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:48] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:48] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:48] [WARN]   op 7 was: move T6/S5 -> T6/S4 Gateway Control Shard (it:188152) x1
[21:25:48] [WARN] Sort: op 7 timed out (no confirm within 4s) [other]
[21:25:44] [WARN] Sort op 7 no-op suspected [sync]: move T6/S5->T6/S4 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:44] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:44] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:44] [WARN]   op 6 was: move T6/S4 -> T6/S3 Gateway Control Shard (it:188152) x1
[21:25:44] [WARN] Sort: op 6 timed out (no confirm within 4s) [other]
[21:25:40] [WARN] Sort op 6 no-op suspected [sync]: move T6/S4->T6/S3 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:40] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:40] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst empty, cursor empty
[21:25:40] [WARN]   op 5 was: move T6/S3 -> T6/S2 Gateway Control Shard (it:188152) x1
[21:25:40] [WARN] Sort: op 5 timed out (no confirm within 4s) [other]
[21:25:35] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x40, dst Silvermoon Health Potion (it:241305) x180
[21:25:35] [WARN]   observed: src Silvermoon Health Potion (it:241305) x100, dst Silvermoon Health Potion (it:241305) x180, cursor empty
[21:25:35] [WARN]   op 4 was: split T6/S37 -> T6/S36 Silvermoon Health Potion (it:241305) x20
[21:25:35] [WARN] Sort: op 4 timed out (no confirm within 4s) [other]
[21:25:31] [WARN] Sort op 4 no-op suspected [sync]: split T6/S37->T6/S36 Silvermoon Health Potion (it:241305) x20 (dst already held expected item; src unchanged)
[21:25:31] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x60, dst Silvermoon Health Potion (it:241305) x180
[21:25:31] [WARN]   observed: src Silvermoon Health Potion (it:241305) x100, dst Silvermoon Health Potion (it:241305) x180, cursor empty
[21:25:31] [WARN]   op 3 was: split T6/S37 -> T6/S35 Silvermoon Health Potion (it:241305) x20
[21:25:31] [WARN] Sort: op 3 timed out (no confirm within 4s) [other]
[21:25:27] [WARN] Sort op 3 no-op suspected [sync]: split T6/S37->T6/S35 Silvermoon Health Potion (it:241305) x20 (dst already held expected item; src unchanged)
[21:25:27] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x80, dst Silvermoon Health Potion (it:241305) x180
[21:25:27] [WARN]   observed: src Silvermoon Health Potion (it:241305) x100, dst Silvermoon Health Potion (it:241305) x180, cursor empty
[21:25:27] [WARN]   op 2 was: split T6/S37 -> T6/S34 Silvermoon Health Potion (it:241305) x20
[21:25:27] [WARN] Sort: op 2 timed out (no confirm within 4s) [other]
[21:25:23] [WARN] Sort op 2 no-op suspected [sync]: split T6/S37->T6/S34 Silvermoon Health Potion (it:241305) x20 (dst already held expected item; src unchanged)
[21:25:22] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x100, dst Silvermoon Health Potion (it:241305) x180
[21:25:22] [WARN]   observed: src Silvermoon Health Potion (it:241305) x100, dst Silvermoon Health Potion (it:241305) x180, cursor empty
[21:25:22] [WARN]   op 1 was: split T6/S37 -> T6/S33 Silvermoon Health Potion (it:241305) x20
[21:25:22] [WARN] Sort: op 1 timed out (no confirm within 4s) [other]
[21:25:19] [WARN] Sort op 1 no-op suspected [sync]: split T6/S37->T6/S33 Silvermoon Health Potion (it:241305) x20 (dst already held expected item; src unchanged)
[21:25:18]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:25:18]   phases: P0 merge=4(free=0) P1a assign=0 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=69
[21:25:18] Sort plan: 5.9ms, 74 ops, 1 deficits, 0 unplaced (input: 515 slots / 7 tabs)
[21:25:13] Sort: replan 1/5 (dst occupied by wrong item at op 33)
[21:25:13] [WARN]   op 33 was: move T6/S56 -> T6/S6 Sunfire Silk Spellthread (it:240133) x6
[21:25:13] [WARN]   planner expected dst at emit: empty
[21:25:13] [WARN] Sort op 33/102 pre-check fail dst T6/S6: expected empty or Sunfire Silk Spellthread (it:240133), got Gateway Control Shard (it:188152) x1
[21:25:13] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:13] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:13] [WARN]   op 32 was: move T6/S6 -> T6/S5 Gateway Control Shard (it:188152) x1
[21:25:13] [WARN] Sort: op 32 timed out (no confirm within 4s) [other]
[21:25:10] [WARN] Sort op 32 no-op suspected [async]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:09] [WARN] Sort op 32 no-op suspected [async]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:09] [WARN] Sort op 32 no-op suspected [sync]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:09] [WARN] Sort op 32 no-op suspected [async]: move T6/S6->T6/S5 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:09] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:09] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:09] [WARN]   op 31 was: move T6/S5 -> T6/S4 Gateway Control Shard (it:188152) x1
[21:25:09] [WARN] Sort: op 31 timed out (no confirm within 4s) [other]
[21:25:05] [WARN] Sort op 31 no-op suspected [async]: move T6/S5->T6/S4 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:05] [WARN] Sort op 31 no-op suspected [async]: move T6/S5->T6/S4 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:05] [WARN] Sort op 31 no-op suspected [sync]: move T6/S5->T6/S4 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:05] [WARN] Sort op 31 no-op suspected [async]: move T6/S5->T6/S4 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:04] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:04] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:04] [WARN]   op 30 was: move T6/S4 -> T6/S3 Gateway Control Shard (it:188152) x1
[21:25:04] [WARN] Sort: op 30 timed out (no confirm within 4s) [other]
[21:25:01] [WARN] Sort op 30 no-op suspected [async]: move T6/S4->T6/S3 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:01] [WARN] Sort op 30 no-op suspected [async]: move T6/S4->T6/S3 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:00] [WARN] Sort op 30 no-op suspected [sync]: move T6/S4->T6/S3 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:00] [WARN] Sort op 30 no-op suspected [async]: move T6/S4->T6/S3 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:25:00] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:25:00] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst Gateway Control Shard (it:188152) x1, cursor empty
[21:25:00] [WARN]   op 29 was: move T6/S3 -> T6/S2 Gateway Control Shard (it:188152) x1
[21:25:00] [WARN] Sort: op 29 timed out (no confirm within 4s) [other]
[21:24:56] [WARN] Sort op 29 no-op suspected [sync]: move T6/S3->T6/S2 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:24:56] [WARN] Sort op 29 no-op suspected [async]: move T6/S3->T6/S2 Gateway Control Shard (it:188152) x1 (dst already held expected item; src unchanged)
[21:24:56] [WARN]   planner expected: src Gateway Control Shard (it:188152) x1, dst empty
[21:24:56] [WARN]   observed: src Gateway Control Shard (it:188152) x1, dst empty, cursor empty
[21:24:56] [WARN]   op 28 was: move T6/S2 -> T6/S1 Gateway Control Shard (it:188152) x1
[21:24:56] [WARN] Sort: op 28 timed out (no confirm within 4s) [other]
[21:24:51] [WARN]   planner expected: src Forest Hunter's Armor Kit (it:244641) x7, dst empty
[21:24:51] [WARN]   observed: src Forest Hunter's Armor Kit (it:244641) x7, dst empty, cursor empty
[21:24:51] [WARN]   op 27 was: split T6/S71 -> T5/S88 Forest Hunter's Armor Kit (it:244641) x1
[21:24:51] [WARN] Sort: op 27 timed out (no confirm within 4s) [other]
[21:24:47] [WARN]   planner expected: src Enchant Weapon - Arcane Mastery (it:244031) x3, dst empty
[21:24:47] [WARN]   observed: src Enchant Weapon - Arcane Mastery (it:244031) x3, dst empty, cursor empty
[21:24:47] [WARN]   op 26 was: split T6/S70 -> T5/S84 Enchant Weapon - Arcane Mastery (it:244031) x1
[21:24:47] [WARN] Sort: op 26 timed out (no confirm within 4s) [other]
[21:24:43] [WARN]   planner expected: src Enchant Weapon - Acuity of the Ren'dorei (it:244029) x4, dst empty
[21:24:43] [WARN]   observed: src Enchant Weapon - Acuity of the Ren'dorei (it:244029) x4, dst empty, cursor empty
[21:24:43] [WARN]   op 25 was: split T6/S69 -> T5/S77 Enchant Weapon - Acuity of the Ren'dorei (it:244029) x1
[21:24:43] [WARN] Sort: op 25 timed out (no confirm within 4s) [other]
[21:24:38] [WARN]   planner expected: src Enchant Shoulders - Silvermoon's Mending (it:244021) x7, dst empty
[21:24:38] [WARN]   observed: src Enchant Shoulders - Silvermoon's Mending (it:244021) x7, dst empty, cursor empty
[21:24:38] [WARN]   op 24 was: split T6/S68 -> T5/S75 Enchant Shoulders - Silvermoon's Mending (it:244021) x1
[21:24:38] [WARN] Sort: op 24 timed out (no confirm within 4s) [other]
[21:24:34] [WARN]   planner expected: src Enchant Ring - Silvermoon's Alacrity (it:244015) x8, dst empty
[21:24:34] [WARN]   observed: src Enchant Ring - Silvermoon's Alacrity (it:244015) x8, dst empty, cursor empty
[21:24:34] [WARN]   op 23 was: split T6/S66 -> T5/S65 Enchant Ring - Silvermoon's Alacrity (it:244015) x1
[21:24:34] [WARN] Sort: op 23 timed out (no confirm within 4s) [other]
[21:24:29] [WARN]   planner expected: src Enchant Shoulders - Amirdrassil's Grace (it:243991) x7, dst empty
[21:24:29] [WARN]   observed: src Enchant Shoulders - Amirdrassil's Grace (it:243991) x7, dst empty, cursor empty
[21:24:29] [WARN]   op 22 was: split T6/S62 -> T5/S52 Enchant Shoulders - Amirdrassil's Grace (it:243991) x1
[21:24:29] [WARN] Sort: op 22 timed out (no confirm within 4s) [other]
[21:24:25] [WARN]   planner expected: src Enchant Chest - Mark of the Worldsoul (it:243977) x12, dst empty
[21:24:25] [WARN]   observed: src Enchant Chest - Mark of the Worldsoul (it:243977) x12, dst empty, cursor empty
[21:24:25] [WARN]   op 21 was: split T6/S58 -> T5/S36 Enchant Chest - Mark of the Worldsoul (it:243977) x1
[21:24:25] [WARN] Sort: op 21 timed out (no confirm within 4s) [other]
[21:24:21] [WARN]   planner expected: src Enchant Weapon - Berserker's Rage (it:243973) x5, dst empty
[21:24:21] [WARN]   observed: src Enchant Weapon - Berserker's Rage (it:243973) x5, dst empty, cursor empty
[21:24:21] [WARN]   op 20 was: split T6/S57 -> T5/S29 Enchant Weapon - Berserker's Rage (it:243973) x1
[21:24:21] [WARN] Sort: op 20 timed out (no confirm within 4s) [other]
[21:24:17] [WARN]   planner expected: src Enchant Ring - Eyes of the Eagle (it:243957) x7, dst empty
[21:24:17] [WARN]   observed: src Enchant Ring - Eyes of the Eagle (it:243957) x8, dst empty, cursor empty
[21:24:17] [WARN]   op 19 was: split T6/S53 -> T5/S20 Enchant Ring - Eyes of the Eagle (it:243957) x1
[21:24:17] [WARN] Sort: op 19 timed out (no confirm within 4s) [other]
[21:24:12] [WARN]   planner expected: src Enchant Ring - Eyes of the Eagle (it:243957) x8, dst empty
[21:24:12] [WARN]   observed: src Enchant Ring - Eyes of the Eagle (it:243957) x8, dst empty, cursor empty
[21:24:12] [WARN]   op 18 was: split T6/S53 -> T5/S17 Enchant Ring - Eyes of the Eagle (it:243957) x1
[21:24:12] [WARN] Sort: op 18 timed out (no confirm within 4s) [other]
[21:24:08] [WARN]   planner expected: src Flawless Quick Garnet (it:240906) x5, dst empty
[21:24:08] [WARN]   observed: src Flawless Quick Garnet (it:240906) x7, dst Flawless Quick Garnet (it:240906) x1, cursor empty
[21:24:08] [WARN]   op 17 was: split T6/S17 -> T4/S50 Flawless Quick Garnet (it:240906) x1
[21:24:08] [WARN] Sort: op 17 timed out (no confirm within 4s) [other]
[21:24:04] [WARN] Sort op 17 no-op suspected [async]: split T6/S17->T4/S50 Flawless Quick Garnet (it:240906) x1 (dst already held expected item; src unchanged)
[21:24:03] [WARN]   planner expected: src Flawless Quick Garnet (it:240906) x6, dst empty
[21:24:03] [WARN]   observed: src Flawless Quick Garnet (it:240906) x7, dst Flawless Quick Garnet (it:240906) x1, cursor empty
[21:24:03] [WARN]   op 16 was: split T6/S17 -> T4/S49 Flawless Quick Garnet (it:240906) x1
[21:24:03] [WARN] Sort: op 16 timed out (no confirm within 4s) [other]
[21:24:00] [WARN] Sort op 16 no-op suspected [async]: split T6/S17->T4/S49 Flawless Quick Garnet (it:240906) x1 (dst already held expected item; src unchanged)
[21:23:59] [WARN]   planner expected: src Flawless Quick Garnet (it:240906) x7, dst empty
[21:23:59] [WARN]   observed: src Flawless Quick Garnet (it:240906) x7, dst Flawless Quick Garnet (it:240906) x1, cursor empty
[21:23:59] [WARN]   op 15 was: split T6/S17 -> T4/S48 Flawless Quick Garnet (it:240906) x1
[21:23:59] [WARN] Sort: op 15 timed out (no confirm within 4s) [other]
[21:23:55] [WARN] Sort op 15 no-op suspected [async]: split T6/S17->T4/S48 Flawless Quick Garnet (it:240906) x1 (dst already held expected item; src unchanged)
[21:23:54] [WARN]   planner expected: src Flawless Quick Amethyst (it:240900) x4, dst empty
[21:23:54] [WARN]   observed: src Flawless Quick Amethyst (it:240900) x8, dst Flawless Quick Amethyst (it:240900) x1, cursor empty
[21:23:54] [WARN]   op 14 was: split T6/S16 -> T4/S35 Flawless Quick Amethyst (it:240900) x1
[21:23:54] [WARN] Sort: op 14 timed out (no confirm within 4s) [other]
[21:23:51] [WARN] Sort op 14 no-op suspected [async]: split T6/S16->T4/S35 Flawless Quick Amethyst (it:240900) x1 (dst already held expected item; src unchanged)
[21:23:50] [WARN]   planner expected: src Flawless Quick Amethyst (it:240900) x5, dst empty
[21:23:50] [WARN]   observed: src Flawless Quick Amethyst (it:240900) x8, dst Flawless Quick Amethyst (it:240900) x1, cursor empty
[21:23:50] [WARN]   op 13 was: split T6/S16 -> T4/S34 Flawless Quick Amethyst (it:240900) x1
[21:23:50] [WARN] Sort: op 13 timed out (no confirm within 4s) [other]
[21:23:47] [WARN] Sort op 13 no-op suspected [async]: split T6/S16->T4/S34 Flawless Quick Amethyst (it:240900) x1 (dst already held expected item; src unchanged)
[21:23:46] [WARN]   planner expected: src Flawless Quick Amethyst (it:240900) x6, dst empty
[21:23:46] [WARN]   observed: src Flawless Quick Amethyst (it:240900) x8, dst Flawless Quick Amethyst (it:240900) x1, cursor empty
[21:23:46] [WARN]   op 12 was: split T6/S16 -> T4/S33 Flawless Quick Amethyst (it:240900) x1
[21:23:46] [WARN] Sort: op 12 timed out (no confirm within 4s) [other]
[21:23:42] [WARN] Sort op 12 no-op suspected [async]: split T6/S16->T4/S33 Flawless Quick Amethyst (it:240900) x1 (dst already held expected item; src unchanged)
[21:23:41] [WARN]   planner expected: src Flawless Quick Amethyst (it:240900) x7, dst empty
[21:23:41] [WARN]   observed: src Flawless Quick Amethyst (it:240900) x8, dst Flawless Quick Amethyst (it:240900) x1, cursor empty
[21:23:41] [WARN]   op 11 was: split T6/S16 -> T4/S32 Flawless Quick Amethyst (it:240900) x1
[21:23:41] [WARN] Sort: op 11 timed out (no confirm within 4s) [other]
[21:23:37] [WARN] Sort op 11 no-op suspected [async]: split T6/S16->T4/S32 Flawless Quick Amethyst (it:240900) x1 (dst already held expected item; src unchanged)
[21:23:37] [WARN]   planner expected: src Flawless Quick Amethyst (it:240900) x8, dst empty
[21:23:37] [WARN]   observed: src Flawless Quick Amethyst (it:240900) x8, dst Flawless Quick Amethyst (it:240900) x1, cursor empty
[21:23:37] [WARN]   op 10 was: split T6/S16 -> T4/S31 Flawless Quick Amethyst (it:240900) x1
[21:23:37] [WARN] Sort: op 10 timed out (no confirm within 4s) [other]
[21:23:33] [WARN] Sort op 10 no-op suspected [async]: split T6/S16->T4/S31 Flawless Quick Amethyst (it:240900) x1 (dst already held expected item; src unchanged)
[21:23:32] Sort op 9 done: move T4/S31->T4/S30 Flawless Deadly Amethyst (it:240898) x1 (0.7s) src=empty dst=Flawless Deadly Amethyst (it:240898) x1
[21:23:31] [WARN]   planner expected: src Flawless Deadly Peridot (it:240890) x9, dst empty
[21:23:31] [WARN]   observed: src Flawless Deadly Peridot (it:240890) x9, dst Flawless Deadly Peridot (it:240890) x1, cursor empty
[21:23:31] [WARN]   op 8 was: split T6/S10 -> T4/S8 Flawless Deadly Peridot (it:240890) x1
[21:23:31] [WARN] Sort: op 8 timed out (no confirm within 4s) [other]
[21:23:29] [WARN] Sort op 8 no-op suspected [async]: split T6/S10->T4/S8 Flawless Deadly Peridot (it:240890) x1 (dst already held expected item; src unchanged)
[21:23:27] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x200, dst empty
[21:23:27] [WARN]   observed: src Silvermoon Health Potion (it:241305) x200, dst Silvermoon Health Potion (it:241305) x20, cursor empty
[21:23:27] [WARN]   op 7 was: split T6/S36 -> T3/S44 Silvermoon Health Potion (it:241305) x20
[21:23:27] [WARN] Sort: op 7 timed out (no confirm within 4s) [other]
[21:23:23] [WARN] Sort op 7 no-op suspected [async]: split T6/S36->T3/S43 Silvermoon Health Potion (it:241305) x20 (dst already held expected item; src unchanged)
[21:23:22] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x200, dst empty
[21:23:22] [WARN]   observed: src Silvermoon Health Potion (it:241305) x200, dst Silvermoon Health Potion (it:241305) x20, cursor empty
[21:23:22] [WARN]   op 6 was: split T6/S35 -> T3/S43 Silvermoon Health Potion (it:241305) x20
[21:23:22] [WARN] Sort: op 6 timed out (no confirm within 4s) [other]
[21:23:19] [WARN] Sort op 6 no-op suspected [async]: split T6/S35->T3/S43 Silvermoon Health Potion (it:241305) x20 (dst already held expected item; src unchanged)
[21:23:18] Sort op 5 done: split T6/S34->T3/S36 Silvermoon Health Potion (it:241305) x20 (3.0s) src=Silvermoon Health Potion (it:241305) x180 dst=Silvermoon Health Potion (it:241305) x20
[21:23:18] Sort: op 4 confirmed by late event after timeout - reclassified as success
[21:23:15] [WARN]   planner expected: src Silvermoon Health Potion (it:241305) x200, dst empty
[21:23:15] [WARN]   observed: src Silvermoon Health Potion (it:241305) x180, dst empty, cursor empty
[21:23:15] [WARN]   op 4 was: split T6/S33 -> T3/S29 Silvermoon Health Potion (it:241305) x20
[21:23:15] [WARN] Sort: op 4 timed out (no confirm within 4s) [other]
[21:23:10] [WARN]   planner expected: src Thalassian Phoenix Oil (it:243733) x20, dst empty
[21:23:10] [WARN]   observed: src Thalassian Phoenix Oil (it:243733) x15, dst empty, cursor empty
[21:23:10] [WARN]   op 3 was: split T6/S7 -> T2/S50 Thalassian Phoenix Oil (it:243733) x5
[21:23:10] [WARN] Sort: op 3 timed out (no confirm within 4s) [other]
[21:23:06] [WARN]   planner expected: src Auto-Hammer (it:132514) x10, dst empty
[21:23:06] [WARN]   observed: src empty, dst empty, cursor empty
[21:23:06] [WARN]   op 2 was: move T6/S1 -> T1/S22 Auto-Hammer (it:132514) x10
[21:23:06] [WARN] Sort: op 2 timed out (no confirm within 4s) [other]
[21:23:02] Sort op 1 done: split T6/S41->T6/S79 Light's Potential (it:241309) x40 (0.8s) src=Light's Potential (it:241309) x20 dst=Light's Potential (it:241309) x200
[21:23:02] [WARN] Sort op 1 no-op suspected [async]: split T6/S41->T6/S79 Light's Potential (it:241309) x40 (dst already held expected item; src unchanged)
[21:23:01] [WARN] Sort op 1 no-op suspected [sync]: split T6/S41->T6/S79 Light's Potential (it:241309) x40 (dst already held expected item; src unchanged)
[21:23:01] [WARN] Sort op 1 no-op suspected [async]: split T6/S41->T6/S79 Light's Potential (it:241309) x40 (dst already held expected item; src unchanged)
[21:23:01] Sort: starting execution of 102 ops
[21:22:51]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:51]   phases: P0 merge=1(free=0) P1a assign=26 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=74
[21:22:51] Sort plan: 8.0ms, 102 ops, 1 deficits, 0 unplaced (input: 491 slots / 7 tabs)
[21:22:43]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:43]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:43] Sort plan: 7.7ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:40]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:40]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:40] Sort plan: 14.6ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:36]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:36]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:36] Sort plan: 5.7ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:33]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:33]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:33] Sort plan: 5.7ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:29]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:29]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:29] Sort plan: 7.4ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:26]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:26]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:26] Sort plan: 5.9ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:22]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:22]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:22] Sort plan: 7.2ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:19]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:19]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:19] Sort plan: 7.5ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:11]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:11]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:11] Sort plan: 5.2ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:22:10]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:22:10]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:22:10] Sort plan: 5.5ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:20:38]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:20:38]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:20:38] Sort plan: 5.3ms, 91 ops, 2 deficits, 0 unplaced (input: 478 slots / 7 tabs)
[21:18:56]   demands: 432 total (pinned=0, ext-R=383, ext-L=0, first-empty=49)
[21:18:56]   phases: P0 merge=0(free=0) P1a assign=24 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=0(abort=0) P3 sweep=0 P4 pack=67
[21:18:56] Sort plan: 7.4ms, 91 ops, 3 deficits, 0 unplaced (input: 478 slots / 7 tabs)
```
