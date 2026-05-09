# Quality Audit Prompt: guild-bank-ledger

Use this file as a prompt to an agent (or as a self-audit checklist) when deciding whether guild-bank-ledger should adopt the four "infra/quality" items described below.

These items were considered for `RCLootCouncil_PriorityLoot` and rejected as premature for that addon's size (a small read-only display layer with no networking). They land differently here: guild-bank-ledger has a real distributed sync protocol (HELLO / SYNC_REQUEST / SYNC_DATA / ACK), an epidemic-gossip layer, a planner with replan logic, and an audit-log surface that has already shipped multiple instrumentation patches. That makes guild-bank-ledger a much better candidate for actual perf, memory, and correctness investment.

## How to use this prompt

Hand this file to an agent with the instruction: "audit guild-bank-ledger against the four items below. For each, recommend KEEP / MAYBE / DROP with a one-paragraph rationale grounded in this repo's actual code paths (not generic best-practice). Then propose a tighter ship sequence with concrete branch names, acceptance criteria, and rough effort estimates."

The agent should ground every verdict in specific file paths or commit references in this repo, not abstract reasoning. Memory entries and `lessons.md` history are fair input.

## The four items

### 1. Performance benchmarks

**The idea.** Add a `bench/` directory with synthetic-fixture scripts and timing assertions. Run them locally (and possibly in CI) so a regression in a hot path surfaces before it ships.

**Why it might matter here.** Sync hot paths are real: `SendSyncWhisper` chunking, `HandleSyncData` per-chunk processing, planner `canExecute` / `applyOpToState`, the bucket-hash computation in fingerprint comparison. Large-guild rosters (100+ players, dozens of bank tabs, weeks of audit history) stress these. A regression that adds 50 ms per chunk on a 200-chunk transfer is invisible in tests but a 10-second extra wait in real use.

**What to investigate.** Profile a representative sync against synthetic fixtures (`spec/fixtures/large_roster.lua` or similar). Identify the top three time-dominant functions. Decide whether timing thresholds in tests are a stable signal (CI hosts vary) or whether benchmarks live as a developer-run check only.

**Acceptance criteria if KEEP.** `bench/` directory with at minimum: full-sync round-trip, planner replan-cap stress test, bucket-fingerprint comparison at large size. README documents how to run. Optional: `BENCH_RESULTS.md` storing baseline numbers per platform.

### 2. Memory audit

**The idea.** Confirm that long-lived state (FontString pools, mixed-in tables, AceComm registrations, sync-state tables, audit-log accumulation) does not leak across `/reload`, frame hide/show, or sync-session lifecycles.

**Why it might matter here.** The audit log persists indefinitely in `RCLootCouncil_GuildBankLedger.SavedVariables` (or your equivalent). The sync protocol holds per-peer state (`syncState.receiving`, chunk buffers, retry counters) that needs explicit teardown on session end. The Layout tab's nested AceGUI widgets have already been a source of anchor-graph bugs (lessons.md 2026-04-28). Memory audit would catch the case where teardown forgets a reference.

**What to investigate.** Use WoW's `/run print(collectgarbage('count'))` before and after specific operations: a full sync, a Layout-tab open/close cycle, opening a transactions tab against a large ledger. Also: search for `tinsert(...)` patterns into module-level tables and verify each has a corresponding teardown / wipe path.

**Acceptance criteria if KEEP.** Document baseline memory numbers, identify any unbounded-growth surface, fix or explicitly bound it. New tests cover teardown paths for any leak class found.

### 3. Mutation testing

**The idea.** Run `mutate.lua` (or equivalent) against the most logic-heavy modules (`src/Sync.lua`, `Planner.lua`, audit-log filtering). The test suite should kill 80%+ of generated mutants.

**Why it might matter here.** The sync protocol has invariants that are hard to test exhaustively (chunk ordering, ACK timing, dedup correctness, replan-cap behaviour). Mutation testing surfaces weak assertions: places where a test passes regardless of whether the code does the right thing. The lessons.md 2026-04-07 entry ("mocks that encode wrong assumptions give false confidence") is the canonical case mutation testing catches.

**What to investigate.** Pick the single highest-impact module. If `src/Sync.lua` mutation surfaces three tests that pass under inversion of an `if`-condition, those tests need real assertions. Decide whether running mutation testing in CI is worth the time cost (it is usually 20-50x slower than the base suite).

**Acceptance criteria if KEEP.** Mutation score reported per module. Tests strengthened until score is 80%+ on the chosen modules. CI runs mutation testing as a non-blocking nightly job, not on every PR.

### 4. Second linter (selene)

**The idea.** Add `selene` (Rust-based Lua linter, modern) alongside `luacheck`. Compare findings, decide which to keep.

**Why it might matter here.** `luacheck` is mature but has known false-positive classes (especially around dynamic dispatch and AceAddon's mixin patterns). `selene` has stricter type-flow analysis and may catch a different class of bug. The tradeoff is maintenance: two linters with two configs.

**What to investigate.** Run `selene` against the current repo. Diff its findings against `luacheck`'s. If selene finds zero net-new useful issues, drop it. If it finds an interesting class (e.g. a specific AceComm-API misuse pattern luacheck misses), promote selene as the second gate; otherwise drop with a note explaining the experiment.

**Acceptance criteria if KEEP.** `selene.toml` config, CI job running selene, and at minimum one finding category that selene catches and luacheck does not, documented in CONTRIBUTING.md.

**Acceptance criteria if DROP.** A short note in `docs/ROADMAP.md` (or this file's followup) explaining what selene was tried against and why it was not adopted, so future contributors do not relitigate the question without new evidence.

## Output expected from the agent

A single audit report with:

1. KEEP / MAYBE / DROP for each of the four items, grounded in this repo's code.
2. Tighter ship sequence (which to do first, in branches, with effort estimates).
3. A list of specific file paths where the work would land.
4. Any additional quality items the agent thinks belong here that are not in the original four.

The audit should follow the same right-sizing principle that produced this prompt: real risk over checkbox theatre, specific over generic, current over hypothetical.
