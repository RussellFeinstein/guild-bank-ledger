# Contributing to GuildBankLedger

Thanks for your interest in contributing! This doc covers how to get set up, what the project expects of a pull request, and the conventions the codebase follows. If anything is unclear, open an issue. Vague docs are a bug.

## Table of contents

- [Quick start](#quick-start)
- [Development workflow](#development-workflow)
- [Commit message format](#commit-message-format)
- [Versioning policy](#versioning-policy)
- [Changelog format](#changelog-format)
- [Tests](#tests)
- [Code style](#code-style)
- [WoW-specific gotchas](#wow-specific-gotchas)
- [Pull request review process](#pull-request-review-process)
- [License](#license)

## Quick start

GuildBankLedger is a Lua 5.1 WoW addon tested with [busted](https://lunarmodules.github.io/busted/) and linted with [luacheck](https://github.com/lunarmodules/luacheck).

1. **Clone**: `git clone https://github.com/RussellFeinstein/guild-bank-ledger.git`
2. **Install Lua 5.1 + LuaRocks** (OS-specific; see [luarocks.org](https://luarocks.org)).
3. **Install test tooling**: `luarocks install busted && luarocks install luacheck`
4. **Run tests**:
   - On Linux / macOS: `busted --verbose`
   - On Windows (Git Bash): `bash run_tests.sh --verbose` (wraps the Windows/MSYS2 PATH setup)
5. **Run the linter**:
   - Linux / macOS: `luacheck .`
   - Windows: `bash run_tests.sh --lint`
6. **Install into WoW** (to test in-game): copy or symlink the repo to your `Interface/AddOns/GuildBankLedger/` directory. Launch WoW with the addon enabled. `/gbl` opens the UI.

## Development workflow

1. Fork the repo (external contributors) or create a branch directly (maintainer).
2. Branch from the current `main`: `git checkout -b my-feature main`.
3. Make your changes with tests.
4. `bash run_tests.sh` and `bash run_tests.sh --lint` must both pass before you push.
5. Push your branch and open a pull request. CI will run tests + lint automatically; the PR cannot be merged until CI is green.
6. The PR template will prompt you for a summary, testing notes, and a checklist. Fill it in. It speeds up review.

`main` is protected: direct pushes are blocked, merge is gated on CI, and the only merge style is a merge commit (so your commits are preserved on `main` with your authorship).

**Maintainer note**: the repo uses long-lived per-area topic branches (`ui`, `sync`, `accessibility`, `layout-sort`) for recurring work, alongside single-purpose `chore/*`, `infra/*`, and `hotfix/*` branches that are frozen once their PR closes (no new commits land on them; follow-up work goes on a new branch off `main`). See the **Branch Workflow** section in [CLAUDE.md](CLAUDE.md) for the full set of rules (rebase cadence, hotfix path, cross-area sequencing, CHANGELOG conflict policy, freeze contract). External contributors don't need to think about this; just branch from `main` and open a PR as described above.

## Commit message format

- **Subject line**: imperative, concise, ≤72 chars. If you bumped versions, suffix with `(vX.Y.Z)`.
- **Body**: explain *why*, not *what* (the diff shows the what). Reference issue numbers, prior incidents, or follow-up work as relevant.
- **Trailers**: `Co-Authored-By: Name <email>` for pair work / AI assistance.

Example:

```
Fix late-ACK reclassification during in-flight ops (v0.29.22)

Without this, a stale ACK arriving after the executor had already
marked a move as failed would re-mark it as ok, corrupting the
progress counter displayed on the Sort tab.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Versioning policy

Follows [Semantic Versioning 2.0](https://semver.org/). Rules of thumb:

- **Patch (x.y.Z)**: bug fixes, internal refactors, performance improvements, docs/tests. No new externally-visible surface.
- **Minor (x.Y.0)**: new features a user or contributor needs to know about. New slash commands, new config keys, new modules, new output/schema types.
- **Major (X.0.0)**: breaking changes. Removed commands, renamed keys, incompatible schema migrations.

The authoritative version is in `VERSION`. Files that must agree: `VERSION`, `GuildBankLedger.toc` (`## Version:` line), `Core.lua` (local `VERSION` string), `CLAUDE.md` (`Current:` line). Every commit that bumps the version must update all four in lockstep, plus add a `CHANGELOG.md` entry and a matching `CHANGELOG_DATA` entry in `UI/ChangelogView.lua`.

**External contributors: leave all version strings alone.** The maintainer handles the version bump and CHANGELOG promotion in a bookkeeping commit after merging your PR. This keeps the repo's version policy entirely on maintainer side so contributors don't have to guess at internal release planning.

## Changelog format

Follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Categories (in order): **Added**, **Changed**, **Fixed**, **Removed**, **Deprecated**, **Security**.

- Each version header: `## [X.Y.Z] - YYYY-MM-DD`
- Entries describe user-visible impact, not internal implementation. *"Fixed sync stall when peer disconnects mid-chunk"*, not *"Added nil check in SendNextChunk"*.
- Group related changes under one version; don't create a separate entry per touched file.

In-addon mirror: `UI/ChangelogView.lua`'s `GBL.CHANGELOG_DATA` table shows the same content inside the game's Changelog tab. Keep the two in sync. If you bump `CHANGELOG.md`, add an entry to `CHANGELOG_DATA` too.

## Tests

- **Every code PR needs tests.** New modules get a new spec file in `spec/`. New features get specs for core logic, edge cases, and error paths. Bug fixes get a regression test that fails without the fix and passes with it.
- **Mocks**: `spec/mock_wow.lua` provides WoW API stubs, `spec/mock_ace.lua` provides Ace3 / AceGUI stubs. Extend them if you need a new API. Do not introduce WoW API calls in tests directly.
- **Test helper**: `spec/helpers.lua` has shared utilities (print capture, timestamp helpers, etc.).
- **Naming**: `spec/foo_spec.lua` tests `Foo.lua`.

If you're touching a module that has no existing spec, adding coverage as part of your PR is strongly preferred over following "I'll test it next time."

## Code style

- **Lua 5.1** only. WoW's Lua runtime is 5.1-plus-some-LuaJIT extensions. Avoid `goto`, 5.2+ integer division, `string.pack`, etc. Pattern check: if `lua5.1 -e "your code"` runs, you're fine.
- **Lines ≤120 chars** (enforced by `.luacheckrc`).
- **Globals**: new globals are a code smell. If you really need one, add it to the `globals` or `read_globals` list in `.luacheckrc` and explain why in the PR.
- **Error handling**: never silently swallow errors. `pcall` is fine; bare `pcall` that drops the error and continues is not.
- **Dates / times**: always `GetServerTime()`, never `time()` or `os.time()`.
- **Item identification**: numeric `classID` / `subclassID` via `C_Item.GetItemInfoInstant()`, never localized strings.

For AI-assisted development (Claude Code, Copilot, etc.), see `CLAUDE.md`. It has more detailed project-specific conventions than this contributor guide.

## WoW-specific gotchas

These come up in ~every sync / bank interaction PR:

- **Guild bank frame events**: `GUILDBANKFRAME_OPENED` / `GUILDBANKFRAME_CLOSED` were removed in WoW 10.0.2. Use `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` / `_HIDE` with `Enum.PlayerInteractionType.GuildBanker`. Guard the enum existence for Classic compatibility.
- **Transaction API**: `GetGuildBankTransaction(tab, i)` returns *relative* time offsets. Compute absolute time via `GetServerTime() - offset`.
- **Money log tab index** is always `MAX_GUILDBANK_TABS + 1` (= 9), **not** `GetNumGuildBankTabs() + 1`. `MAX_GUILDBANK_TABS` is a compile-time constant for purchasable tab slots.
- **Money transaction types**: the API returns `"withdrawal"` (not `"withdraw"`). Normalize at record creation.
- **Per-tab slot cap**: `MAX_GUILDBANK_SLOTS_PER_TAB = 98`.
- **Query before read**: call `QueryGuildBankLog(tab)` before reading transactions and `QueryGuildBankTab(tab)` before reading slots. Data is not available synchronously.
- **Sync is guild-wide.** All guild members running the addon participate in the HELLO / SYNC protocol. **Never add officer-rank checks to the sync protocol.** Rank-based access control gates *UI visibility* only.

## Pull request review process

1. Open your PR against `main`. Fill in the PR template.
2. CI runs (`busted` + `luacheck`). Iterate until green.
3. The maintainer will review. For most PRs this is a day or two, faster for small fixes.
4. On approval, the maintainer merges with a merge commit (your commits stay intact on `main` with your authorship). If you're not bumping versions / CHANGELOG, a follow-up bookkeeping commit handles that.
5. External contributor branches (forks) are untouched on merge. Short-lived maintainer branches (`chore/*`, `infra/*`, `hotfix/*`) can be deleted manually after merge. The long-lived topic branches (`ui`, `sync`, `accessibility`, `layout-sort`) are kept on the remote and reused across sessions, so they are not deleted on merge.

Maintainer note: if CI is flaky in a way that cannot be fixed inside the PR (e.g., GitHub Actions outage), the `main-protection` ruleset can be temporarily disabled from **Settings → Rules → Rulesets**. Re-enable immediately after.

## License

GuildBankLedger is MIT-licensed (see `LICENSE`). By opening a PR you agree your contribution is licensed the same way. No separate CLA.
