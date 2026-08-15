# Contributing to GuildBankLedger

Thanks for your interest in contributing! This doc covers how to get set up, what the project expects of a pull request, and the conventions the codebase follows. If anything is unclear, open an issue. Vague docs are a bug.

## Table of contents

- [Quick start](#quick-start)
- [Development workflow](#development-workflow)
- [Labels and milestones](#labels-and-milestones)
- [Commit message format](#commit-message-format)
- [Versioning policy](#versioning-policy)
- [Changelog format](#changelog-format)
- [Tests](#tests)
- [Code style](#code-style)
- [Data model](#data-model)
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

**Maintainer note**: `main` is the only permanent branch. Maintainer work goes on single-purpose, type-prefixed branches (`feat/`, `fix/`, `chore/`, `infra/`, `hotfix/`), one PR each, deleted automatically when the PR merges. See the **Branch Workflow** section in [CLAUDE.md](CLAUDE.md) for the full set of rules (rebase cadence, hotfix path, cross-branch sequencing, version-stamp cadence). External contributors don't need to think about this; just branch from `main` and open a PR as described above.

## Labels and milestones

Every issue and every pull request carries labels on two axes. The rule for each label is written into that label's own description on GitHub, so you can read it from the sidebar without opening this file.

**`type:` says what kind of change it is.** One per item, and it mirrors the branch prefixes above, so the label predicts the branch name:

| Label | Branch prefix |
|---|---|
| `type: bug` | `fix/`, `hotfix/` |
| `type: enhancement` | `feat/` |
| `type: chore` | `chore/` |
| `type: infra` | `infra/` |
| `type: refactor` | `refactor/` |
| `type: documentation` | `chore/` (there is no `docs/` prefix; the label is applied by hand) |

**`area:` says what part of the addon it touches.** At least one per item: `area: sync`, `area: storage`, `area: sort`, `area: restock`, `area: layout`, `area: ui`, `area: accessibility`, `area: repo`. A second area only where the item has separate acceptance criteria in two places.

This axis is the one that pays off later. Milestones are chronological arcs: they close, and a closed milestone stops working as a lookup tool. The area label is the only thing that can answer "what has this repo ever done to sync" across all of them, which is why closed issues and merged PRs carry labels too, not just open work.

`good first issue`, `help wanted`, `question`, `duplicate`, `invalid` and `wontfix` are GitHub's defaults. They sit outside both axes and neither invariant applies to them.

**What this means for you as a contributor:**

- **You do not need to apply labels, and GitHub will not let you.** Applying labels needs triage permission on the repo, so the control is absent from the UI and `gh issue edit --add-label` returns 403. That is expected, not a misconfiguration. An unlabeled new issue is the normal starting state; the maintainer labels it during triage.
- **Put in the body what a label would have carried.** Which part of the addon it affects, whether it is a defect or a request, and anything that blocks it.
- **Pull requests label themselves.** [.github/workflows/labeler.yml](.github/workflows/labeler.yml) applies `type:` from your branch prefix and `area:` from the files you changed, with rules in [.github/labeler.yml](.github/labeler.yml). The path globs are coarse, so a PR spanning subsystems picks up several area labels. The maintainer corrects what the globs get wrong; you do not need to.

Milestones are release arcs, and membership means the work gates that arc rather than that it is urgent. `Sort rework`, `Restock rework`, `Data model integrity`, `Sync reliability`, `Accessibility to v1.0` and `Codebase refactor` are the current set. An issue with no milestone is not neglected; it is unscheduled on purpose.

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

The authoritative version is in `VERSION`. Files that must agree: `VERSION`, `GuildBankLedger.toc` (`## Version:` line), `src/Core.lua` (local `VERSION` string), `CLAUDE.md` (`Current:` line). Every commit that bumps the version must update all four in lockstep, plus add a `CHANGELOG.md` entry and a matching `CHANGELOG_DATA` entry in `UI/ChangelogView.lua`.

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

## Data model

Before changing anything that touches stored records, dedup, or the sync payload, read
[docs/DATA-MODEL.md](docs/DATA-MODEL.md). It documents what the SavedVariables file actually holds
rather than what the AceDB defaults declare, and the two differ in ways that read as bugs until you
have traced them. It covers record identity and why the dedup prefix is hard to change, the
`schemaVersion` migration ladder, the `peers` name collision between the persisted and runtime
tables, and what sync intake validation does and does not guarantee. Each disagreement it records
carries a verdict and an issue number; those are collected under the **Data model integrity**
milestone.

One rule from it is easy to break by accident and worth stating here. **A record arriving over sync
keeps any field the receiver does not recognize.** That tolerance is the reason adding a field to a
record costs nothing today. Validating intake against a list of known keys would look like a cleanup
and would quietly make every future field a breaking change, because older clients would strip it.

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
5. External contributor branches (forks) are untouched on merge. Maintainer branches are deleted automatically when the PR merges; the commits live on `main` and the PR record keeps the history.

Maintainer note: if CI is flaky in a way that cannot be fixed inside the PR (e.g., GitHub Actions outage), the `main-protection` ruleset can be temporarily disabled from **Settings → Rules → Rulesets**. Re-enable immediately after.

## License

GuildBankLedger is MIT-licensed (see `LICENSE`). By opening a PR you agree your contribution is licensed the same way. No separate CLA.
